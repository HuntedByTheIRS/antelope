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

/// Parallel execution configuration.
struct ParallelConfig
{
    /// Maximum parallel jobs (0 = unlimited, 1 = serial).
    uint jobs = 1;
    /// Targets excluded from parallel builds.
    string[] notParallelTargets;
    /// Whether to use jobserver protocol for sub-makes.
    bool useJobserver = true;
}
