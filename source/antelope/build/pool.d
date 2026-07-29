/// Parallel build worker pool with dependency-aware scheduling.
///
/// Uses D's `std.concurrency` Actor model for worker coordination:
///   - Workers are spawned as OS threads via `spawn()`
///   - The main thread acts as coordinator: maintains the ready queue,
///     dispatches BuildJob messages to workers, and receives JobDone results
///   - No shared mutable state — all communication is via message passing
///
/// Features:
///   - Ready queue with critical-path priority sorting (load-aware scheduling)
///   - Fine-grained dispatch: targets become ready immediately when their
///     last prerequisite completes (not batched)
///   - Worker pool reuse: N threads spawned once, reused for all targets
///   - Configurable job limits (-jN)
///   - Correct failure propagation: failed targets mark dependents as skipped
///   - .NOTPARALLEL support: targets run exclusively when all workers idle
///   - Output buffering via OutputManager for atomic per-target printing
module antelope.build.pool;

import core.thread : Thread;
import std.concurrency : spawn, send, receive, receiveOnly, receiveTimeout,
    Tid, thisTid, ownerTid;
import std.algorithm : sort;
import std.conv : to;

import antelope.build.target;
import antelope.build.graph;
import antelope.build.dependency;
import antelope.build.output;
import antelope.build.executor;
import antelope.shell.process;
import antelope.shell.environment;
import antelope.filesystem.timestamps;
import antelope.compatibility.parallel;
import antelope.compatibility.vpath;
import antelope.diagnostics.output;

// ── Messages ────────────────────────────────────────────────────────────

/// Sent from coordinator to worker: "build this target."
struct BuildJob
{
    string targetName;                /// Target to build
    immutable(string)[] expandedRecipe;  /// Pre-expanded recipe lines
    immutable(bool)[] ignoreErrors;      /// Per-line: - prefix
    immutable(bool)[] silent;            /// Per-line: @ prefix
    immutable(string)[] execEnv;         /// KEY=VALUE environment
    bool dryRun;                         /// If true, echo but don't execute
}

/// Sent from worker to coordinator: "target built (or failed)."
struct JobDone
{
    Tid workerTid;                   /// Which worker completed
    string targetName;               /// Which target was built
    bool success;                    /// True if all recipe lines succeeded
    int exitCode;                    /// Last non-zero exit code (0 on success)
    bool hadEcho;                    /// True if any recipe line was echoed (non-@)
    immutable(string)[] stdoutLines; /// Captured stdout lines
    immutable(string)[] stderrLines; /// Captured stderr lines
}

/// Sent from coordinator to worker: "exit your loop."
struct Shutdown {}

// ── WorkerPool ───────────────────────────────────────────────────────────

/// Manages parallel build execution.
///
/// Usage:
/// ```d
/// auto pool = WorkerPool(config.jobs);
/// int exitCode = pool.build(graph, rootTargets, config, env, expander, output, vpath);
/// ```
struct WorkerPool
{
private:
    uint numWorkers;                /// Number of worker threads (= -j value)
    Tid[] workerTids;               /// Tids of spawned workers
    bool started;                   /// Whether workers have been spawned

    // Build state (populated during build())
    DependencyGraph* graph;
    ParallelConfig* parallelConfig;
    OutputManager* outputMgr;
    VPathConfig* vpathConfig;           /// VPATH for needsRebuild in dequeueDependents
    bool[string] notParallelSet;       /// Targets marked .NOTPARALLEL
    bool[string] failedSet;         /// Targets that failed (for propagation)
    bool[string] skippedSet;        /// Targets blocked by failed prereqs

    // Ready queue (sorted by descending criticalWeight)
    // Stored as indices into graph.targets
    size_t[] readyQueue;

    // Dependency tracking
    size_t[string] remainingDeps;

    // .JOBS throttle: tracks active workers per job-limit value.
    size_t[size_t] activeByLimit;

    // Completed target counter (shared between build() and dequeueDependents).
    size_t completedCount;

public:
    /// Create a worker pool with the given number of workers.
    ///
    /// If `numWorkers` is 0, it defaults to the number of CPU cores.
    /// If `numWorkers` is 1, the build runs serially without spawning threads.
    static WorkerPool create(uint numWorkers = 0)
    {
        import std.parallelism : totalCPUs;
    WorkerPool pool;
    if (numWorkers == 0)
        pool.numWorkers = totalCPUs;
    else
        pool.numWorkers = numWorkers;
    return pool;
}

/// Jobserver file descriptors for cross-process token coordination.
/// readFd is passed to child processes via MAKEFLAGS; writeFd is
/// held by the parent to return tokens after job completion.
struct JobserverPipe
{
    int readFd = -1;    /// Read end — child processes consume tokens here
    int writeFd = -1;   /// Write end — parent writes tokens back on completion
    bool active;         /// Whether the jobserver is operational
}

/// Create a jobserver pipe with `nTokens` initial tokens.
///
/// Writes N bytes to the pipe so that up to N jobs can run
/// concurrently across recursive $(MAKE) invocations.  Each job
/// reads one byte before starting; the byte is written back on
/// completion.
static JobserverPipe createJobserverPipe(uint nTokens)
{
    version (Posix)
    {
        import core.sys.posix.unistd : pipe, read, write, close;
        import core.sys.posix.fcntl : fcntl, F_SETFD, FD_CLOEXEC;

        JobserverPipe js;
        int[2] fds;

        if (pipe(fds) != 0)
            return js;

        // Write end: mark close-on-exec so child processes only
        // inherit the read end.
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);

        js.readFd = fds[0];
        js.writeFd = fds[1];
        js.active = true;

        // Seed the pipe with N tokens (one byte each).
        ubyte token = 0;
        for (uint i = 0; i < nTokens; i++)
            write(js.writeFd, &token, 1);

        return js;
    }
    else
    {
        // Non-POSIX: jobserver not supported.
        return JobserverPipe();
    }
}

/// Consume one token from the jobserver pipe (blocking).
/// Returns true if a token was acquired, false on error.
private static bool acquireJobserverToken(int readFd)
{
    version (Posix)
    {
        import core.sys.posix.unistd : read;
        ubyte token;
        return read(readFd, &token, 1) == 1;
    }
    else
        return false;
}

/// Return one token to the jobserver pipe.
private static bool releaseJobserverToken(int writeFd)
{
    version (Posix)
    {
        import core.sys.posix.unistd : write;
        ubyte token = 0;
        return write(writeFd, &token, 1) == 1;
    }
    else
        return false;
}

    /// Run the build for the given root targets.
    ///
    /// Params:
    ///   graph       = Dependency graph with all targets (mutated: runtime state fields)
    ///   roots       = Root target names to build (e.g., ["all"])
    ///   config      = Parallel config (jobs, notParallelTargets, output sync mode)
    ///   env         = Build environment (passed to recipe subprocesses)
    ///   expander    = Variable expansion delegate
    ///   output      = Output buffer manager
    ///   vpath       = VPATH config (for needsRebuild checks)
    ///   baseExecEnv = KEY=VALUE pairs added to every job's env (e.g., SHELL, MAKEFLAGS)
    ///   dryRun      = Print commands without executing
    ///   silent      = Suppress command echoing
    ///
    /// Returns: exit code (0 = success, non-zero = failure).
    int build(
        ref DependencyGraph graph,
        string[] roots,
        ref ParallelConfig config,
        Environment* env,
        string delegate(string, string, string[], string) expander,
        OutputManager* output,
        VPathConfig* vpath,
        string[] baseExecEnv = [],
        bool dryRun = false,
        bool silent = false)
    {
        import antelope.filesystem.timestamps;

        this.graph = &graph;
        this.parallelConfig = &config;
        this.outputMgr = output;
        this.vpathConfig = vpath;

        // Determine actual worker count.
        uint nWorkers = config.jobs;
        if (nWorkers == 0)
        {
            import std.parallelism : totalCPUs;
            nWorkers = totalCPUs;
        }

        // Reset per-build state.
        readyQueue = [];
        failedSet = null;
        skippedSet = null;
        remainingDeps = null;

        // Serial mode shortcut.
        if (nWorkers <= 1)
            return buildSerial(graph, roots, config, env, expander, output,
                vpath, baseExecEnv, dryRun, silent);

        // Build the combined transitive closure for all root targets.
        bool[string] inClosure;
        foreach (root; roots)
        {
            auto closure = graph.transitiveClosure(root);
            foreach (name; closure)
                inClosure[name] = true;
        }

        if (inClosure.length == 0)
            return 0;

        // Set up scheduling state.
        graph.resetSchedulingState();
        graph.buildReverseEdges();

        import antelope.build.dependency;
        foreach (root; roots)
            computeCriticalWeights(graph, root);

        graph.computeRemainingDeps();

        // Copy remainingDeps for fast lookup BEFORE the init loop so
        // that dequeueDependents (called for up-to-date targets during
        // initial ready-queue construction) can read from it.
        remainingDeps = null;
        foreach (ref t; graph.targets)
            if (t.name in inClosure)
                remainingDeps[t.name] = t.remainingDeps;

        // Populate initial ready queue: targets with remainingDeps == 0
        // that actually need building and are in the closure.
        size_t[] initialReady;
        foreach (i, ref t; graph.targets)
        {
            if (t.name !in inClosure)
                continue;
            if (t.remainingDeps != 0)
                continue;
            if (!needsRebuild(t.name, t.prerequisites,
                    &graph.phonyTargets, vpath, &t.orderOnlyPrereqs))
            {
                t.state = BuildState.completed;
                // Notify dependents so they can become ready.
                dequeueDependents(t.name);
                continue;
            }
            initialReady ~= i;
        }

        // Sort initial-ready targets by descending critical weight.
        initialReady.sort!((a, b) =>
            graph.targets[a].criticalWeight > graph.targets[b].criticalWeight);

        // Merge initial-ready targets with any targets that became ready
        // during the init loop (via dequeueDependents for up-to-date
        // prerequisites).  Initial-ready goes first (already filtered
        // by needsRebuild), then dequeueDependents-added targets.
        readyQueue = initialReady ~ readyQueue;

        size_t totalTargets = 0;
        foreach (i, ref t; graph.targets)
            if (t.name in inClosure && t.state != BuildState.completed)
                totalTargets++;

        // Spawn worker threads.
        workerTids.length = 0;
        for (uint i = 0; i < nWorkers; i++)
        {
            auto tid = spawn(&workerFunc);
            workerTids ~= tid;
        }
        this.numWorkers = nWorkers;
        this.started = true;

        // Seed idle worker queue: all workers start idle.
        Tid[] idleWorkers = workerTids.dup;

        // Send initial batch of jobs (respect .JOBS and .NOTPARALLEL limits).
        completedCount = 0;
        while (readyQueue.length > 0 && idleWorkers.length > 0)
        {
            size_t idx = readyQueue[0];

            // NOTPARALLEL: only dispatch when all other workers are idle.
            if (idx < graph.targets.length &&
                graph.targets[idx].name in notParallelSet &&
                idleWorkers.length != workerTids.length)
                break;

            // .JOBS limit: throttle if this target has a job limit.
            if (idx < graph.targets.length &&
                graph.targets[idx].jobLimit > 0)
            {
                size_t busy = workerTids.length - idleWorkers.length;
                if (busy >= graph.targets[idx].jobLimit)
                    break;
            }

            readyQueue = readyQueue[1 .. $];
            auto job = makeBuildJob(idx, env, expander, baseExecEnv, dryRun);
            if (job.expandedRecipe.length > 0)
            {
                graph.targets[idx].state = BuildState.running;
                send(idleWorkers[$ - 1], job);
                idleWorkers = idleWorkers[0 .. $ - 1];
                if (graph.targets[idx].jobLimit > 0)
                    activeByLimit[graph.targets[idx].jobLimit]++;
            }
            else
            {
                // Target with no recipe: mark complete immediately.
                graph.targets[idx].state = BuildState.completed;
                dequeueDependents(graph.targets[idx].name);
                completedCount++;
            }
        }

        // Coordinator loop: dispatch → receive → process → repeat.
        bool hasFailure = false;

        while (completedCount < totalTargets)
        {
            // Phase 1: Dispatch as many ready targets as possible
            // to idle workers.
            while (readyQueue.length > 0 && idleWorkers.length > 0)
            {
                size_t idx = readyQueue[0];

                // NOTPARALLEL: only dispatch when all other workers are idle.
                if (idx < graph.targets.length &&
                    graph.targets[idx].name in notParallelSet &&
                    idleWorkers.length != workerTids.length)
                    break;

                // .JOBS limit: throttle if this target has a job limit.
                // Tracks only workers running .JOBS-limited targets of
                // the same limit value, not total busy workers.
                if (idx < graph.targets.length &&
                    graph.targets[idx].jobLimit > 0)
                {
                    size_t limit = graph.targets[idx].jobLimit;
                    auto countPtr = limit in activeByLimit;
                    size_t active = countPtr ? *countPtr : 0;
                    if (active >= limit)
                        break;
                }

                readyQueue = readyQueue[1 .. $];
                auto job = makeBuildJob(idx, env, expander, baseExecEnv, dryRun);
                if (job.expandedRecipe.length > 0)
                {
                    graph.targets[idx].state = BuildState.running;
                    send(idleWorkers[$ - 1], job);
                    idleWorkers = idleWorkers[0 .. $ - 1];
                    if (graph.targets[idx].jobLimit > 0)
                        activeByLimit[graph.targets[idx].jobLimit]++;
                }
                else
                {
                    // Target with no recipe: complete immediately.
                    graph.targets[idx].state = BuildState.completed;
                    dequeueDependents(graph.targets[idx].name);
                    completedCount++;
                }
            }

            // Phase 2: Check termination.
            if (idleWorkers.length == workerTids.length)
            {
                // All workers idle.  If work remains, targets are
                // blocked (waiting for failed/skipped prereqs).
                if (completedCount < totalTargets)
                {
                    foreach (ref t; graph.targets)
                    {
                        if (t.name !in inClosure)
                            continue;
                        if (t.state == BuildState.pending)
                        {
                            t.state = BuildState.skipped;
                            skippedSet[t.name] = true;
                            completedCount++;
                            if (output && output.buffered)
                                output.flush(t.name);
                        }
                    }
                }
                break;
            }

            // Phase 3: Wait for a worker result.
            auto done = receiveOnly!JobDone();

            // Worker is now idle.
            idleWorkers ~= done.workerTid;

            // Buffer output into OutputManager.
            if (output)
            {
                foreach (line; done.stdoutLines)
                    output.bufferStdout(done.targetName, cast(string) line);
                foreach (line; done.stderrLines)
                    output.bufferStderr(done.targetName, cast(string) line);
                if (done.hadEcho)
                    output.markEchoed(done.targetName);
            }

            // Phase 4: Process result.
            auto tp = graph.findTarget(done.targetName);
            if (tp !is null)
            {
                // Decrement .JOBS throttle counter if this target had a limit.
                if (tp.jobLimit > 0)
                {
                    auto countPtr = tp.jobLimit in activeByLimit;
                    if (countPtr && *countPtr > 0)
                        (*countPtr)--;
                }

                if (done.success)
                {
                    tp.state = BuildState.completed;
                    log(LogLevel.dbg, "[" ~ done.targetName ~ "] completed");
                    dequeueDependents(done.targetName);
                }
                else
                {
                    tp.state = BuildState.failed;
                    failedSet[done.targetName] = true;
                    hasFailure = true;
                    log(LogLevel.dbg, "[" ~ done.targetName ~
                        "] FAILED (exit " ~ done.exitCode.to!string ~ ")");
                    propagateFailure(done.targetName, inClosure);
                }
            }

            // Flush buffered output.
            if (output && output.buffered)
                output.flush(done.targetName);

            completedCount++;
            // Loop back to Phase 1 (dispatch newly-ready targets).
        }

        // Shutdown all workers.
        foreach (tid; workerTids)
        {
            try { send(tid, Shutdown()); } catch (Exception) {}
        }

        // Collect any late messages (workers may have sent results
        // that haven't been received yet due to timing).
        // Use a short timeout to drain the queue.
        import core.time : dur;
        while (true)
        {
            auto msg = receiveTimeout(dur!"msecs"(100), (JobDone d) => true);
            if (!msg)
                break;
        }

        workerTids = [];
        started = false;

        return hasFailure ? 1 : 0;
    }

private:
    /// Serial fallback for -j1 or single-worker builds.
    int buildSerial(
        ref DependencyGraph graph,
        string[] roots,
        ref ParallelConfig config,
        Environment* env,
        string delegate(string, string, string[], string) expander,
        OutputManager* output,
        VPathConfig* vpath,
        string[] baseExecEnv,
        bool dryRun,
        bool silent)
    {
        import antelope.filesystem.timestamps : needsRebuild;

        bool hasFailure;

        foreach (root; roots)
        {
            auto batches = resolveDependencies(graph, root);
            foreach (batch; batches)
            {
                foreach (ref t; batch)
                {
                    if (!needsRebuild(t.name, t.prerequisites,
                            &graph.phonyTargets, vpath, &t.orderOnlyPrereqs))
                        continue;

                    string[] execEnv = baseExecEnv.dup;

                    auto result = executeTarget(t, execEnv, expander,
                        output, dryRun, silent);
                    if (output && output.buffered)
                        output.flush(t.name);

                    if (!result.success)
                    {
                        hasFailure = true;
                        goto done;
                    }
                }
            }
        }

    done:
        return hasFailure ? 1 : 0;
    }

    /// Worker thread function.
    static void workerFunc()
    {
        import std.string : stripLeft;
        bool running = true;

        while (running)
        {
            receive(
                (BuildJob job) {
                    JobDone done;
                    done.workerTid = thisTid;
                    done.targetName = job.targetName;
                    done.success = true;
                    done.exitCode = 0;
                    done.hadEcho = false;

                    // Build mutable output buffers, freeze before sending.
                    string[] outLines;
                    string[] errLines;

                    if (job.expandedRecipe.length == 0)
                    {
                        done.stdoutLines = outLines.idup;
                        done.stderrLines = errLines.idup;
                        send(ownerTid, done);
                        return;
                    }

                    foreach (i, line; job.expandedRecipe)
                    {
                        // line is immutable(string); cast to string for stdlib.
                        string sline = cast(string) line;
                        if (sline.stripLeft.length == 0)
                            continue;

                        bool ignoreErrors = i < job.ignoreErrors.length
                            ? cast(bool) job.ignoreErrors[i] : false;
                        bool silent = i < job.silent.length
                            ? cast(bool) job.silent[i] : false;

                        // Echo
                        if (!silent)
                        {
                            done.hadEcho = true;
                            outLines ~= sline;
                        }

                        // Dry run: skip actual execution.
                        if (job.dryRun)
                            continue;

                        // Execute. Cast execEnv back to mutable for runProcessPiped.
                        auto ph = runProcessPiped(sline, cast(string[]) job.execEnv);

                        // Read pipes.
                        try
                        {
                            import std.string : chomp;

                            foreach (pl; ph.stdoutPipe.byLine)
                            {
                                string s = pl.chomp().idup;
                                outLines ~= s;
                            }

                            foreach (pl; ph.stderrPipe.byLine)
                            {
                                string s = pl.chomp().idup;
                                errLines ~= s;
                            }
                        }
                        catch (Exception e)
                        {
                            // Log pipe read errors but don't abort the build.
                            log(LogLevel.dbg, "[" ~ job.targetName ~
                                "] pipe read error: " ~ e.msg);
                        }

                        int code = ph.waitFor();

                        if (code != 0 && !ignoreErrors)
                        {
                            ph.closePipes();
                            done.success = false;
                            done.exitCode = code;
                            done.stdoutLines = outLines.idup;
                            done.stderrLines = errLines.idup;
                            send(ownerTid, done);
                            return;
                        }

                        ph.closePipes();
                    }

                    done.stdoutLines = outLines.idup;
                    done.stderrLines = errLines.idup;
                    send(ownerTid, done);
                },
                (Shutdown _) {
                    running = false;
                }
            );
        }
    }

    /// Create a BuildJob for the target at graph index `idx`.
    BuildJob makeBuildJob(
        size_t idx,
        Environment* env,
        string delegate(string, string, string[], string) expander,
        string[] baseExecEnv,
        bool dryRun)
    {
        auto t = &graph.targets[idx];

        // Build mutable arrays, then freeze to immutable for sending.
        string[] recipeLines;
        bool[] ignoreErrs;
        bool[] silents;

        foreach (line; t.recipe)
        {
            // Expand variables in the recipe.
            string expanded = expander(line, t.name,
                t.prerequisites, t.stem);

            // Strip and classify prefix characters.
            import std.string : stripLeft;
            string trimmed = expanded.stripLeft();
            bool ignoreErrors;
            bool silent;

            if (trimmed.length > 0)
            {
                bool stripping = true;
                while (stripping && trimmed.length > 0)
                {
                    stripping = false;
                    switch (trimmed[0])
                    {
                        case '@':
                            silent = true;
                            trimmed = trimmed[1 .. $];
                            stripping = true;
                            break;
                        case '-':
                            ignoreErrors = true;
                            trimmed = trimmed[1 .. $];
                            stripping = true;
                            break;
                        case '+':
                            trimmed = trimmed[1 .. $];
                            stripping = true;
                            break;
                        default:
                            break;
                    }
                }
            }

            if (trimmed.length == 0)
                continue;

            recipeLines ~= trimmed;
            ignoreErrs ~= ignoreErrors;
            silents ~= silent;
        }

        // Build execEnv.
        string[] execEnvArr = baseExecEnv.dup;

        // Freeze arrays to immutable for std.concurrency message passing.
        BuildJob job;
        job.targetName = t.name;
        job.expandedRecipe = recipeLines.idup;
        job.ignoreErrors = ignoreErrs.idup;
        job.silent = silents.idup;
        job.execEnv = execEnvArr.idup;
        job.dryRun = dryRun;

        return job;
    }

    /// Decrement remainingDeps for all dependents of `completedTarget`.
    /// Any dependent that reaches 0 remaining deps is added to the
    /// ready queue (sorted by descending critical weight).
    void dequeueDependents(string completedTarget)
    {
        auto tp = graph.findTarget(completedTarget);
        if (tp is null)
            return;

        foreach (depName; tp.dependents)
        {
            // Skip if not in our tracking (could be outside closure).
            auto depPtr = depName in remainingDeps;
            if (depPtr is null)
                continue;

            if (*depPtr == 0)
                continue; // Already ready or completed

            (*depPtr)--;

            if (*depPtr == 0 && !(depName in skippedSet))
            {
                // Target is now ready — check if it needs building.
                auto dep = graph.findTarget(depName);
                if (dep is null || dep.state != BuildState.pending)
                    continue;

                // Check up-to-date: targets that become ready via
                // dequeueDependents were NOT filtered during the init
                // loop (which only checks initially-zero-dep targets).
                import antelope.filesystem.timestamps : needsRebuild;
                if (!needsRebuild(dep.name, dep.prerequisites,
                        &graph.phonyTargets, vpathConfig, &dep.orderOnlyPrereqs))
                {
                    dep.state = BuildState.completed;
                    completedCount++;
                    dequeueDependents(dep.name);
                    continue;
                }

                // Insert sorted by descending critical weight.
                bool inserted;
                foreach (i, qi; readyQueue)
                {
                    if (dep.criticalWeight > graph.targets[qi].criticalWeight)
                    {
                        readyQueue = readyQueue[0 .. i] ~
                            [cast(size_t)(dep - graph.targets.ptr)] ~
                            readyQueue[i .. $];
                        inserted = true;
                        break;
                    }
                }
                if (!inserted)
                    readyQueue ~= cast(size_t)(dep - graph.targets.ptr);
            }
        }
    }

    /// Mark all dependents of a failed target as skipped.
    /// Recursively propagates: if A depends on B and B fails,
    /// A is skipped; if C depends on A, C is also skipped.
    void propagateFailure(string failedTarget, ref bool[string] inClosure)
    {
        import std.algorithm : canFind;

        string[] stack = [failedTarget];

        while (stack.length > 0)
        {
            string current = stack[$ - 1];
            stack = stack[0 .. $ - 1];

            auto tp = graph.findTarget(current);
            if (tp is null)
                continue;

            foreach (depName; tp.dependents)
            {
                if (depName in skippedSet || depName in failedSet)
                    continue;
                if (depName !in inClosure)
                    continue;

                auto dep = graph.findTarget(depName);
                if (dep is null)
                    continue;

                dep.state = BuildState.skipped;
                skippedSet[depName] = true;
                stack ~= depName;
            }
        }
    }
}

// ── Unittests ────────────────────────────────────────────────────────────

///
unittest
{
    // Build a trivial graph with one target (no recipe).
    DependencyGraph g;
    g.addTarget(Target("leaf", TargetKind.file, [], []));

    g.buildReverseEdges();
    g.computeRemainingDeps();
    computeCriticalWeights(g, "leaf");

    ParallelConfig pc;
    pc.jobs = 2;

    auto om = new OutputManager();

    string expand(string ln, string tn, string[] pr, string st) { return ln; }

    auto pool = WorkerPool.create(2);
    int code = pool.build(g, ["leaf"], pc, null, &expand, &om, null);
    assert(code == 0);
    assert(g.findTarget("leaf").state == BuildState.completed);
}

///
unittest
{
    // Chain: a → b → c (all no recipe, always succeed).
    DependencyGraph g;
    g.addTarget(Target("c", TargetKind.file, [], []));
    g.addTarget(Target("b", TargetKind.file, ["c"], []));
    g.addTarget(Target("a", TargetKind.file, ["b"], []));

    // Ensure all are in the closure.
    g.buildReverseEdges();
    g.computeRemainingDeps();
    computeCriticalWeights(g, "a");

    ParallelConfig pc;
    pc.jobs = 2;

    auto om = new OutputManager();
    string expand(string ln, string tn, string[] pr, string st) { return ln; }

    auto pool = WorkerPool.create(2);
    int code = pool.build(g, ["a"], pc, null, &expand, &om, null);
    assert(code == 0);
    assert(g.findTarget("a").state == BuildState.completed);
    assert(g.findTarget("b").state == BuildState.completed);
    assert(g.findTarget("c").state == BuildState.completed);
}

// Regression: serial mode (jobs=1) should work.
unittest
{
    DependencyGraph g;
    g.addTarget(Target("x", TargetKind.file, [], []));

    g.buildReverseEdges();
    g.computeRemainingDeps();
    computeCriticalWeights(g, "x");

    ParallelConfig pc;
    pc.jobs = 1;

    auto om = new OutputManager();
    string expand(string ln, string tn, string[] pr, string st) { return ln; }

    auto pool = WorkerPool.create(1);
    int code = pool.build(g, ["x"], pc, null, &expand, &om, null);
    assert(code == 0);
}
