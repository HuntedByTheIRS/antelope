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
    import antelope.shell.environment;
    import antelope.filesystem.timestamps;

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
    import std.file : thisExePath;
    string makeCmd = thisExePath();
    if (config.gnuMode) makeCmd ~= " -gnu";
    if (config.file.length > 0) makeCmd ~= " -f " ~ config.file;
    env.set("MAKE", makeCmd);

    // Set MAKECMDGOALS from command-line targets (autotools compat)
    if (config.targets.length > 0)
    {
        import std.string : join;
        env.set("MAKECMDGOALS", config.targets.join(" "));
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

    // Check for cycle errors
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

    // .PHONY targets are tracked in the graph automatically via handlePhony()

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

    // Build each requested target
    int exitCode = 0;
    foreach (targetName; buildTargets)
    {
        if (!graph.hasTarget(targetName))
        {
            log(LogLevel.normal, "antelope: *** No rule to make target '" ~
                targetName ~ "'.  Stop.");
            return 1;
        }

        // Resolve dependencies and check what needs building
        auto batches = resolveDependencies(*graph, targetName);

        import std.stdio;
        if (targetName == "libgnu.a" || targetName == "all") {
            stderr.writefln("  batches=%d", batches.length);
            foreach (i, batch; batches) {
                size_t w;
                foreach (ref t; batch) if (t.recipe.length > 0) w++;
                stderr.writefln("    batch[%d]: %d targets, %d with recipe", i, batch.length, w);
            }
        }

        bool builtSomething = false;
        foreach (batch; batches)
        {
            foreach (ref t; batch)
            {
                if (!needsRebuild(t.name, t.prerequisites,
                    &graph.phonyTargets, &vpath, &t.orderOnlyPrereqs))
                    continue;

                builtSomething = true;

                // Execute recipe lines
                foreach (recipeLine; t.recipe)
                {
                    // Expand variables in the recipe
                    string expanded = expand(recipeLine, env, t.name,
                        t.prerequisites);

                    // Print the command unless silent (@ prefix)
                    import std.string : stripLeft;
                    string trimmed = recipeLine.stripLeft();
                    if (config.dryRun || config.debugMode || recipeLine.length == 0 ||
                        (trimmed.length > 0 && trimmed[0] != '@'))
                    {
                        log(LogLevel.normal, expanded);
                    }

                    // Build environment for recipe execution
                    // (propagate SHELL from Makefile if set)
                    string[] execEnv;
                    if (env.hasKey("SHELL"))
                        execEnv ~= "SHELL=" ~ env.get("SHELL");

                    // Serialize MAKEFLAGS for recursive $(MAKE) calls
                    import antelope.compatibility.submake;
                    string makeFlags = serializeMakeFlags(config);
                    if (makeFlags.length > 0)
                        execEnv ~= "MAKEFLAGS=" ~ makeFlags;

                    // Execute unless dry run
                    if (!config.dryRun)
                    {
                        auto result = execute(expanded, execEnv);
                        if (!result.success)
                        {
                            log(LogLevel.normal, "antelope: *** [" ~ t.name ~
                                "] Error " ~ result.exitCode.to!string);
                            return result.exitCode;
                        }
                    }
                }
            }
        }

        if (!builtSomething)
        {
            log(LogLevel.normal, "antelope: '" ~ targetName ~
                "' is up to date.");
        }
    }

    return exitCode;
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
