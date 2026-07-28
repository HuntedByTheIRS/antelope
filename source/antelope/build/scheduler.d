/// Build job scheduler — decides execution order and parallelism.
///
/// Uses Kahn's-algorithm topological sort (via `resolveDependencies`) to
/// determine build order, then filters targets that actually need rebuilding
/// by comparing file timestamps.
module antelope.build.scheduler;

import antelope.build.graph;
import antelope.build.dependency;
import antelope.build.target;
import antelope.filesystem.timestamps;

/// Available scheduler strategies.
///
/// The strategy controls how the build order is consumed by the executor:
///   serial      — Process targets one at a time in dependency order.
///   parallel    — Build targets within each topological batch concurrently.
///   topological — Return the pure dependency order without filtering
///                 for up-to-date targets (useful for inspection).
///
/// The current implementation always uses topological batching; the
/// strategy is threaded through so the executor can decide whether to
/// run batches serially or in parallel.
enum SchedulerStrategy
{
    serial,
    parallel,
    topological,
}

/// Schedule and return an ordered list of target names to build.
///
/// Steps:
///   1. Determine the root target — tries "all" (GNU Make convention),
///      falls back to the first target in the graph.
///   2. Run Kahn's topological sort to produce build batches.
///   3. For each target, check `needsRebuild()` against its prerequisites
///      to decide whether it actually needs to be built.
///   4. Flatten batches into a single ordered `string[]`.
///
/// Targets that are up-to-date (target file exists and is newer than all
/// prereqs) are skipped.
///
/// Params:
///   graph    = The dependency graph containing all known targets.
///   strategy = How the executor should consume the output (serial,
///              parallel, or raw topological).
///
/// Returns:
///   Ordered list of target names that need building.  Returns an empty
///   array when the graph has no targets or the root target is untraceable.
string[] schedule(DependencyGraph graph, SchedulerStrategy strategy)
{
    // 1. Pick the default target.
    string targetName;
    if (graph.hasTarget("all"))
        targetName = "all";
    else if (graph.targets.length > 0)
        targetName = graph.targets[0].name;
    else
        return [];

    // 2. Resolve full dependency tree into topological batches.
    Target[][] batches = resolveDependencies(graph, targetName);
    if (batches.length == 0)
        return [];

    // 3. Collect targets that actually need building.
    string[] buildOrder;

    foreach (batch; batches)
    {
        foreach (ref tgt; batch)
        {
            // In topological mode, include every target regardless of
            // freshness (useful for inspection / dry-run analysis).
            final switch (strategy)
            {
                case SchedulerStrategy.topological:
                    buildOrder ~= tgt.name;
                    break;
                case SchedulerStrategy.serial:
                case SchedulerStrategy.parallel:
                    if (needsRebuild(tgt.name, tgt.prerequisites, &graph.phonyTargets))
                        buildOrder ~= tgt.name;
                    break;
            }
        }
    }

    return buildOrder;
}

///
unittest
{
    // Simple chain: leaf1, leaf2 → middle.
    // middle must be the first target added (and thus the default)
    // so that the scheduler picks it up as the root.
    DependencyGraph g;
    g.addTarget(Target("middle", TargetKind.file, ["leaf1", "leaf2"], []));
    g.addTarget(Target("leaf1", TargetKind.file, [], []));
    g.addTarget(Target("leaf2", TargetKind.file, [], []));

    // All targets should need rebuilding (files don't exist on disk).
    auto order = schedule(g, SchedulerStrategy.serial);
    assert(order.length == 3);

    // In topological mode, no filtering is applied.
    auto topoOrder = schedule(g, SchedulerStrategy.topological);
    assert(topoOrder.length == 3);
}

/// Regression: "all" target takes priority as the default root.
unittest
{
    DependencyGraph g;
    g.addTarget(Target("somethingElse", TargetKind.file, [], []));
    g.addTarget(Target("all", TargetKind.phony, ["somethingElse"], []));

    auto order = schedule(g, SchedulerStrategy.serial);
    // All targets should be in the build order (phony + file).
    assert(order.length == 2);
}

/// Regression: empty graph returns empty order.
unittest
{
    DependencyGraph g;
    auto order = schedule(g, SchedulerStrategy.serial);
    assert(order.length == 0);
}
