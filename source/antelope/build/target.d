/// Target representation — files, phony targets, and their metadata.
module antelope.build.target;

/// What kind of target this is.
enum TargetKind
{
    file,
    phony,
    intermediate,
}

/// Runtime scheduling state for parallel builds.
///
/// Tracks where a target is in the build lifecycle so the worker pool
/// can make dispatch decisions.
enum BuildState
{
    pending,     /// Not yet ready — outstanding in-graph prerequisites
    ready,       /// All prereqs satisfied, can be dispatched to a worker
    running,     /// Currently being built by a worker thread
    completed,   /// Built successfully
    failed,      /// Build failed — dependents will be skipped
    skipped,     /// Blocked by a failed prerequisite
}

/// A single build target.
struct Target
{
    string name;
    TargetKind kind;
    string[] prerequisites;        /// Normal prerequisites (trigger rebuild)
    string[] recipe;               /// Shell commands to build this target
    string[] orderOnlyPrereqs;     /// Order-only prerequisites (| — must exist, no rebuild trigger)
    string stem;                   /// Pattern/suffix rule stem for $* expansion

    // ── Runtime scheduling fields ───────────────────────────────────────

    /// Current build state (mutated by the worker pool coordinator).
    BuildState state = BuildState.pending;

    /// How many in-graph prerequisites still need to complete before this
    /// target becomes `ready`.  Set by `DependencyGraph.computeRemainingDeps()`
    /// before the build begins.
    size_t remainingDeps;

    /// Critical-path weight for load-aware scheduling.
    ///
    /// Computed as: `recipe.length + max(successor.criticalWeight)`.
    /// Leaf nodes (no in-graph successors) have weight = `recipe.length`.
    /// Higher weight → on the critical path → should be scheduled first
    /// when multiple targets are in the ready queue.
    size_t criticalWeight;

    /// Reverse edges: names of targets that list this target as a prerequisite.
    /// Populated by `DependencyGraph.buildReverseEdges()` before scheduling.
    /// When this target completes, every name in this list will have its
    /// `remainingDeps` decremented.
    string[] dependents;

    /// Per-target job limit for .JOBS special target (native mode only).
    /// 0 = use the global pool limit.  Non-zero = maximum concurrent
    /// jobs allowed for this specific target's recipe group.
    size_t jobLimit;
}
