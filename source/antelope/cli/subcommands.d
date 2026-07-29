/// Subcommand dispatch — routes to the appropriate handler.
///
/// Antelope's CLI pattern is: antelope <subcommand> <options> --[flags]
/// The subcommand is the first positional argument; it defaults to `build`.
module antelope.cli.subcommands;

import antelope.cli.args;
import antelope.cli.help;
import antelope.cli.verinfo;
import antelope.diagnostics.output;
import std.file : exists, readText;
import std.conv : to;

/// Dispatch to the correct handler based on CliConfig.subcommand.
/// Returns an exit code (0 = success).
int dispatchSubcommand(CliConfig config)
{
    final switch (config.subcommand)
    {
        case Subcommand.build:
            return runBuild(config);
        case Subcommand.hunt:
            return runHunt(config);
        case Subcommand.configure:
            return runConfigure(config);
    }
}

/// Execute the build (default subcommand).
///
/// Full pipeline: find build file → parse → evaluate → schedule → execute.
/// The schedule/execute phases now use the parallel WorkerPool for
/// dependency-aware concurrent builds when `-j > 1`.
int runBuild(CliConfig config)
{
    import antelope.parser.parser;
    import antelope.parser.ast;
    import antelope.evaluator.evaluator;
    import antelope.evaluator.expansion;
    import antelope.build.graph;
    import antelope.build.target;
    import antelope.build.dependency;
    import antelope.build.scheduler;
    import antelope.build.executor;
    import antelope.build.pool;
    import antelope.build.output;
    import antelope.shell.environment;
    import antelope.filesystem.timestamps;
    import antelope.compatibility.parallel;
    import antelope.compatibility.submake;

    // Set log level
    if (config.debugMode)
        setLogLevel(LogLevel.dbg);

    // Change to target directory (-C <dir>)
    if (config.directory.length > 0)
    {
        import std.file : chdir;
        try { chdir(config.directory); }
        catch (Exception e)
        {
            log(LogLevel.normal, "antelope: cannot chdir to " ~ config.directory ~ ": " ~ e.msg);
            return 1;
        }
    }

    // Find build file
    string buildFile = findBuildFile(config);
    if (buildFile.length == 0)
    {
        if (config.gnuMode)
            log(LogLevel.normal, "antelope: *** No targets specified and no makefile found.  Stop.");
        else
            log(LogLevel.normal, "antelope: *** No build file found.  Stop.");
        return 1;
    }
    log(LogLevel.verbose, "Using build file: " ~ buildFile);

    // Read the build file
    string content;
    try
    {
        content = readText(buildFile);
    }
    catch (Exception e)
    {
        log(LogLevel.normal, "antelope: *** Cannot read build file: " ~ buildFile);
        return 1;
    }

    // Parse into AST
    AstNode ast;
    try
    {
        ast = parse(content);
    }
    catch (Exception e)
    {
        log(LogLevel.normal, "antelope: *** Parse error: " ~ e.msg);
        return 1;
    }

    // Setup environment with OS env
    auto env = new Environment();
    {
        import std.process : environment;
        env.mergeEnv(environment.toAA());
    }

    // Set MAKE to the antelope binary path for $(MAKE) in recipes.
    // Include -gnu so recursive sub-makes inherit GNU compat mode.
    // config.file is shell-quoted to prevent injection when $(MAKE)
    // is used in recipes.
    import std.file : thisExePath;
    string makeCmd = thisExePath();
    if (config.gnuMode) makeCmd ~= " -gnu";
    if (config.file.length > 0) makeCmd ~= " -f '" ~ escapeShell(config.file) ~ "'";
    env.set("MAKE", makeCmd);

    // Set MAKECMDGOALS from command-line targets (autotools compat)
    if (config.targets.length > 0)
    {
        import std.string : join;
        env.set("MAKECMDGOALS", config.targets.join(" "));
    }

    // Parse MAKEFLAGS for variable overrides propagated from parent
    // antelope processes via recursive $(MAKE).  These are serialized
    // in MAKEFLAGS as "VAR=value" tokens.
    if (env.hasKey("MAKEFLAGS"))
    {
        import std.string : split, indexOf;
        import std.algorithm : startsWith;
        auto mkFlags = env.get("MAKEFLAGS");
        foreach (word; mkFlags.split(" "))
        {
            auto eqPos = indexOf(word, '=');
            if (eqPos > 0 && !word.startsWith("-"))
            {
                string varName = word[0 .. eqPos];
                string varValue = word[eqPos + 1 .. $];
                config.varOverrides[varName] = varValue;
            }
        }
    }

    // Apply command-line variable overrides (VAR=value args) BEFORE
    // Makefile evaluation so they take precedence over Makefile
    // assignments.  GNU Make semantics: command-line vars beat
    // everything except `override` directives.
    foreach (varName, varValue; config.varOverrides)
    {
        env.setCmdOverride(varName, varValue);
    }

    // Evaluate AST → populate env + build graph
    auto graph = new DependencyGraph();

    // --- GNU Make compatibility (gnu_make.d) ---
    import antelope.compatibility.gnu_make;
    GnuMakeCompat gnuCompat;
    if (config.gnuMode)
        gnuCompat = GnuMakeCompat.withDefaults();

    // --- POSIX conformance mode (posix_make.d) ---
    import antelope.compatibility.posix_make;
    PosixCompat posixCompat;
    if (config.posix)
        posixCompat.mode = PosixConformance.strict;

    try
    {
        evaluate(ast, env, graph, &gnuCompat, &posixCompat);
    }
    catch (Exception e)
    {
        log(LogLevel.normal, "antelope: *** Evaluation error: " ~ e.msg);
        return 1;
    }

    // Process special targets after evaluation populates the graph.
    (*graph).handlePhony();
    (*graph).handleWait();
    (*graph).handleJobs();

    // Check for cycle errors
    (*graph).detectCycles();
    if (graph.cycleErrors.length > 0)
    {
        foreach (err; graph.cycleErrors)
            log(LogLevel.normal, "antelope: *** " ~ err.message);
        return 1;
    }

    // In -gnu mode (and not POSIX strict), resolve implicit rules for
    // targets without recipes.  POSIX strict mode disables GNU extensions
    // including implicit rule resolution.
    // This fills in recipes from the built-in rule database (e.g.
    // %.o: %.c and %: %.o) so that targets with no explicit recipe
    // can still be built.  Multiple passes handle rule chaining:
    // "program" → link rule adds "program.o" → compile rule adds
    // "program.c".  Safety cap of 10 passes prevents infinite loops.
    if (config.gnuMode && !config.posix)
    {
        import antelope.evaluator.evaluator : resolveImplicitRules;
        const size_t maxPasses = 5;  // deep enough for .l → .c → .s → .o chains
        for (size_t pass = 0; pass < maxPasses; pass++)
        {
            auto resolved = resolveImplicitRules(*graph, env);
            log(LogLevel.dbg, "Implicit rule pass " ~
                (pass + 1).to!string ~ ": " ~ resolved.to!string ~
                " target(s) resolved");
            if (resolved == 0)
                break;
        }
    }

    if (graph.targets.length == 0)
    {
        log(LogLevel.verbose, "No targets defined.");
        return 0;
    }

    // Determine which targets to build
    string[] buildTargets;
    if (config.targets.length > 0)
        buildTargets = config.targets;
    else if (graph.hasTarget("all"))
        buildTargets = ["all"];
    else
        buildTargets = [graph.targets[0].name];

    // .PHONY + .WAIT + .JOBS targets are processed above via handlePhony/handleWait/handleJobs.

    // --- VPATH configuration (GNU Make compat) ---
    import antelope.compatibility.vpath;
    VPathConfig vpath;
    if (config.gnuMode && env.hasKey("VPATH"))
    {
        import std.string : split;
        string vpathVal = env.get("VPATH");
        foreach (dir; vpathVal.split(":"))
        {
            if (dir.length > 0)
                vpath.globalSearchDirs ~= dir;
        }
    }
    // Also read pattern-scoped vpath entries stored by handleDirective
    if (config.gnuMode)
    {
        import std.string : split, startsWith;
        foreach (key; env.keys())
        {
            if (key.length > 8 && key[0..8] == "__vpath_")
            {
                string pattern = key[8..$];
                string dirsStr = env.get(key);
                VPathEntry entry;
                entry.pattern = pattern;
                foreach (dir; dirsStr.split(" "))
                    if (dir.length > 0) entry.directories ~= dir;
                if (entry.directories.length > 0)
                    vpath.patternEntries ~= entry;
            }
        }
    }

    // --- Resolve implicit targets (GNU Make compat) ---
    // Targets requested on the command line might not exist in the graph
    // yet — they may be defined only via pattern/suffix rules.
    // We create stubs and run implicit rule resolution so they can be built.
    foreach (targetName; buildTargets)
    {
        if (!graph.hasTarget(targetName))
        {
            import antelope.build.target;
            Target stub;
            stub.name = targetName;
            stub.kind = TargetKind.file;
            graph.addTarget(stub);

            import antelope.evaluator.evaluator : resolveImplicitRules;
            resolveImplicitRules(*graph, env);
        }
    }

    // --- Set up parallel execution config ---
    ParallelConfig parallelCfg;
    parallelCfg.jobs = config.jobs;
    parallelCfg.heuristic = SchedulingHeuristic.criticalPath;

    // Check for .NOTPARALLEL targets in the graph.
    if (graph.hasTarget(".NOTPARALLEL"))
    {
        auto np = graph.findTarget(".NOTPARALLEL");
        if (np !is null)
        {
            foreach (name; np.prerequisites)
                parallelCfg.notParallelTargets ~= name;
        }
    }

    // Output mode: buffer when parallel, live when serial.
    auto outputMgr = new OutputManager();
    if (config.jobs > 1 || config.jobs == 0)
    {
        outputMgr.buffered = true;
        parallelCfg.outputSync = OutputSyncMode.target;
    }

    // --- Build base execution environment ---
    string[] baseExecEnv;
    if (env.hasKey("SHELL"))
        baseExecEnv ~= "SHELL=" ~ env.get("SHELL");

    // Create jobserver pipe for cross-process token coordination.
    // Only created when parallel build is active (-j > 1).
    // Create jobserver pipe for cross-process token coordination.
    // Only created when parallel build is active (-j > 1).
    import antelope.build.pool : WorkerPool;
    WorkerPool.JobserverPipe jsPipe;
    if (config.jobs > 1)
        jsPipe = WorkerPool.createJobserverPipe(config.jobs);

    // Serialize MAKEFLAGS for recursive $(MAKE) calls.
    string makeFlags = serializeMakeFlags(config, jsPipe.readFd, jsPipe.writeFd);
    if (makeFlags.length > 0)
        baseExecEnv ~= "MAKEFLAGS=" ~ makeFlags;

    // --- Variable expansion delegate ---
    // Captured by the pool and called per-target during job construction.
    // This delegates to the existing expand() function from the evaluator,
    // threading through the global Environment and target context.
    string expander(string line, string targetName,
                    string[] prerequisites, string stem)
    {
        return expand(line, env, targetName, prerequisites, stem);
    }

    // --- Dispatch build ---
    auto pool = WorkerPool.create(config.jobs);
    int exitCode = pool.build(
        *graph, buildTargets, parallelCfg, env,
        &expander, &outputMgr, &vpath,
        baseExecEnv, config.dryRun, false);

    // Report up-to-date targets (tracks targets that had no work).
    if (exitCode == 0)
    {
        bool anyBuilt;
        foreach (targetName; buildTargets)
        {
            auto tp = graph.findTarget(targetName);
            if (tp !is null && tp.state == BuildState.completed)
            {
                if (tp.recipe.length == 0 && !outputMgr.hasEchoed(targetName))
                {
                    // Target was up-to-date or had no recipe.
                }
                else if (!outputMgr.hasEchoed(targetName))
                {
                    log(LogLevel.normal, "antelope: '" ~ targetName ~
                        "' is up to date.");
                }
                anyBuilt = true;
            }
        }
        if (!anyBuilt)
        {
            // Check if nothing needed building (all targets already up to date).
        }
    }

    return exitCode;
}

/// Escape a string for single-quoted shell usage.
/// Replaces each `'` with `'\''` so the value can be wrapped in single quotes.
private string escapeShell(string s)
{
    import std.array : replace;
    return s.replace("'", "'\\''");
}

/// Find which build file to use based on mode and config.
private string findBuildFile(CliConfig config)
{
    // Explicitly specified file
    if (config.file.length > 0)
    {
        if (exists(config.file))
            return config.file;
        log(LogLevel.normal, "antelope: " ~ config.file ~ ": No such file");
        return "";
    }

    // GNU Make mode: GNUmakefile, Makefile, makefile
    if (config.gnuMode)
    {
        if (exists("GNUmakefile"))  return "GNUmakefile";
        if (exists("Makefile"))     return "Makefile";
        if (exists("makefile"))     return "makefile";
        return "";
    }

    // Native mode: antefile, antelope (case-insensitive)
    if (exists("antefile"))   return "antefile";
    if (exists("Antefile"))   return "Antefile";
    if (exists("ANTEFILE"))   return "ANTEFILE";
    if (exists("antelope"))   return "antelope";
    if (exists("Antelope"))   return "Antelope";
    return "";
}

/// Convert a Makefile to an Antefile (context-aware, late-stage feature).
int runHunt(CliConfig config)
{
    log(LogLevel.normal, "Antelope hunt — not yet implemented");
    return 0;
}

/// Run autotools configure.ac replacement (future feature).
int runConfigure(CliConfig config)
{
    log(LogLevel.normal, "Antelope configure — not yet implemented");
    return 0;
}
