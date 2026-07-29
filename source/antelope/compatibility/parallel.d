/// GNU Make parallel execution semantics.
///
/// GNU Make's -j flag and related features control parallel execution:
///   - .NOTPARALLEL       — disable parallelism for specific targets
///   - .WAIT              — wait for previous prerequisites before continuing
///   - .JOBS              — job pool (GNU Make 4.4+)
///   - jobserver protocol — pipe-based job token passing
///
/// This module defines the parallel execution model that Antelope uses
/// when compatibility with GNU Make's -j behavior is required.
module antelope.compatibility.parallel;

/// Parallel execution special targets.
enum ParallelSpecialTarget
{
    notparallel,     /// .NOTPARALLEL
    wait,            /// .WAIT
    jobs,            /// .JOBS
}

/// Output synchronisation mode for parallel builds.
///
/// GNU Make 4.0+ supports `--output-sync` with four modes.
enum OutputSyncMode
{
    none,      /// No synchronisation — output may be interleaved (default)
    target,    /// Buffer output per target, print atomically on completion
    line,      /// Buffer output per line, print atomically per line
    recurse,   /// Buffer output per recursive make invocation
}

/// Which scheduling heuristic to use when multiple targets are ready.
enum SchedulingHeuristic
{
    fifo,            /// First-in-first-out — build order is topological order
    criticalPath,    /// Prioritise targets on the critical path (minimise total build time)
}

/// Parallel execution configuration.
struct ParallelConfig
{
    /// Maximum parallel jobs (0 = unlimited, 1 = serial).
    uint jobs = 1;

    /// Targets excluded from parallel builds (.NOTPARALLEL).
    /// These always run serially, even when -j > 1.
    string[] notParallelTargets;

    /// Whether to use jobserver protocol for sub-makes.
    bool useJobserver = true;

    /// How to synchronise output from parallel jobs.
    OutputSyncMode outputSync = OutputSyncMode.none;

    /// Which heuristic to use for ordering the ready queue.
    SchedulingHeuristic heuristic = SchedulingHeuristic.criticalPath;

    /// Timeout in seconds for individual recipe lines (0 = no timeout).
    /// GNU Make does not natively support job timeouts; this is an
    /// Antelope extension.
    uint jobTimeoutSecs = 0;
}
