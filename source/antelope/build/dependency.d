/// Dependency resolution and ordering logic.
///
/// Uses Kahn's algorithm (BFS-based topological sort) to produce ordered
/// build batches, plus critical-path weight computation for load-aware
/// scheduling.
module antelope.build.dependency;

import antelope.build.graph;
import antelope.build.target;
import antelope.diagnostics.errors;

/// Resolve the full transitive closure of prerequisites and return an
/// array of build batches using Kahn's algorithm.
///
/// Each batch is a slice of targets that can be built in parallel — all
/// of their in-graph prerequisites have been satisfied by earlier batches.
///
/// Params:
///   graph  = The dependency graph containing all known targets.
///   target = The root build target to resolve dependencies for.
///
/// Returns:
///   An array of batches `Target[][]` ordered from leaf to root.
///   Returns an empty array if the target is not found in the graph.
///
/// Example:
///   target `program` with deps `main.o` → `main.c`, `util.o` → `util.c`
///   Returns: `[[main.c, util.c], [main.o, util.o], [program]]`
Target[][] resolveDependencies(DependencyGraph graph, string target)
{
    // 1. Find the root target
    auto rootTarget = graph.findTarget(target);
    if (rootTarget is null)
        return [];

    // 2. Compute transitive closure — only follow prereqs that exist
    //    as graph targets. Missing prereqs are treated as external files
    //    (already satisfied, don't contribute to in-degree).
    bool[string] inClosure;
    string[] stack = [target];

    while (stack.length > 0)
    {
        string current = stack[$ - 1];
        stack = stack[0 .. $ - 1];

        if (current in inClosure)
            continue;
        inClosure[current] = true;

        auto tp = graph.findTarget(current);
        if (tp is null)
            continue;

        // Only follow prereqs that exist as graph targets.
        // External prereqs (source files, etc.) are treated as
        // already-satisfied and do not trigger stub creation.
        foreach (prereq; tp.prerequisites)
        {
            if (prereq !in inClosure && graph.hasTarget(prereq))
                stack ~= prereq;
        }
        foreach (prereq; tp.orderOnlyPrereqs)
        {
            if (prereq !in inClosure && graph.hasTarget(prereq))
                stack ~= prereq;
        }
    }

    // 3. Build a fast name → Target lookup for graph targets in the closure.
    Target[string] targetMap;
    foreach (ref t; graph.targets)
        if (t.name in inClosure)
            targetMap[t.name] = t;

    // 4. Compute in-degree for each target: the number of its prereqs
    //    that are also targets in the graph (and therefore need building).
    size_t[string] inDegree;
    string[][string] dependents; // prereq → list of dependents

    foreach (name; inClosure.keys)
        inDegree[name] = 0;

    foreach (name, ref tgt; targetMap)
    {
        size_t unresolved;
        foreach (prereq; tgt.prerequisites)
        {
            if (prereq in targetMap)
            {
                unresolved++;
                dependents[prereq] ~= name;
            }
        }
        // Order-only prereqs also need building
        foreach (prereq; tgt.orderOnlyPrereqs)
        {
            if (prereq in targetMap)
            {
                unresolved++;
                dependents[prereq] ~= name;
            }
        }
        inDegree[name] = unresolved;
    }

    // 5. Kahn's algorithm — process in batches.
    Target[][] batches;
    string[] currentBatch;

    // Seed with all nodes that have no unresolved in-graph prereqs.
    foreach (name; inClosure.keys)
    {
        if (inDegree[name] == 0)
            currentBatch ~= name;
    }

    while (currentBatch.length > 0)
    {
        Target[] batch;
        foreach (name; currentBatch)
        {
            auto tp = name in targetMap;
            if (tp !is null)
                batch ~= *tp;
        }
        if (batch.length > 0)
            batches ~= batch;

        // Decrement in-degree for all dependents of the current batch.
        string[] nextBatch;
        foreach (name; currentBatch)
        {
            auto deps = name in dependents;
            if (deps is null)
                continue;
            foreach (dep; *deps)
            {
                inDegree[dep]--;
                if (inDegree[dep] == 0)
                    nextBatch ~= dep;
            }
        }
        currentBatch = nextBatch;
    }

    // 6. If any nodes still have inDegree > 0, there's a cycle.
    //    Those targets will never reach batch 0 and won't appear in
    //    the output — the caller should detect that some targets are
    //    missing from the batches.
    return batches;
}

/// Compute critical-path weights for every target reachable from `root`.
///
/// The critical-path weight of a target is:
///   weight = recipe.length + max(weight of each successor)
///
/// A "successor" is any target that depends on this target (i.e., a
/// target listing this one as a prerequisite).  This is the reverse
/// of the usual dependency direction — we compute from the root
/// backward to the leaves.
///
/// Leaf nodes (targets with no in-graph dependents) have weight = recipe.length.
/// Root nodes accumulate the full chain of work beneath them.
///
/// The resulting weights are written directly into each `Target.criticalWeight`
/// field.  The caller sorts the ready queue by descending `criticalWeight`
/// to prioritize targets on the critical path.
///
/// Params:
///   graph = The dependency graph with reverse edges already populated
///           via `DependencyGraph.buildReverseEdges()`.
///   root  = The root target name to start the weight computation from.
void computeCriticalWeights(ref DependencyGraph graph, string root)
{
    import std.algorithm : max;

    // Only consider targets reachable from the root.
    bool[string] reachable;
    {
        string[] stack = [root];
        while (stack.length > 0)
        {
            string current = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            if (current in reachable)
                continue;
            reachable[current] = true;
            auto tp = graph.findTarget(current);
            if (tp is null)
                continue;
            foreach (dep; tp.prerequisites ~ tp.orderOnlyPrereqs)
                if (graph.hasTarget(dep) && dep !in reachable)
                    stack ~= dep;
        }
    }

    // Build a dependency map: node → all in-graph prereqs
    string[][string] prereqMap;
    foreach (ref t; graph.targets)
    {
        if (t.name !in reachable)
            continue;
        foreach (p; t.prerequisites ~ t.orderOnlyPrereqs)
            if (p in reachable && graph.hasTarget(p))
                prereqMap[t.name] ~= p;
    }

    // Kahn-style topological order from leaves (in-degree 0) to root.
    size_t[string] inDegree;
    string[][string] dependentsMap; // prereq → dependents

    foreach (name; reachable.keys)
        inDegree[name] = 0;

    foreach (name, prereqs; prereqMap)
    {
        inDegree[name] = prereqs.length;
        foreach (p; prereqs)
            dependentsMap[p] ~= name;
    }

    // Process in topological order: all of a node's prereqs are
    // processed before the node itself, so their weights are finalised.
    string[] queue;
    foreach (name; reachable.keys)
        if (inDegree[name] == 0)
            queue ~= name;

    string[] order;
    while (queue.length > 0)
    {
        string current = queue[$ - 1];
        queue = queue[0 .. $ - 1];
        order ~= current;

        auto deps = current in dependentsMap;
        if (deps is null)
            continue;
        foreach (dep; *deps)
        {
            inDegree[dep]--;
            if (inDegree[dep] == 0)
                queue ~= dep;
        }
    }

    // Now compute weights in topological order.
    // order[0] = leaf, order[$-1] = root.
    foreach (name; order)
    {
        auto tp = graph.findTarget(name);
        if (tp is null)
            continue;

        size_t maxPrereqWeight = 0;
        auto prereqs = name in prereqMap;
        if (prereqs)
        {
            foreach (p; *prereqs)
            {
                auto pp = graph.findTarget(p);
                if (pp !is null)
                    maxPrereqWeight = max(maxPrereqWeight, pp.criticalWeight);
            }
        }
        tp.criticalWeight = tp.recipe.length + maxPrereqWeight;
    }
}

///
unittest
{
    // Build a test graph:
    //   program → main.o  → main.c
    //   program → util.o  → util.c
    DependencyGraph g;
    g.addTarget(Target("main.c", TargetKind.file, [], []));
    g.addTarget(Target("util.c", TargetKind.file, [], []));
    g.addTarget(Target("main.o", TargetKind.file, ["main.c"], ["gcc -c main.c"]));
    g.addTarget(Target("util.o", TargetKind.file, ["util.c"], ["gcc -c util.c"]));
    g.addTarget(Target("program", TargetKind.file,
        ["main.o", "util.o"], ["gcc -o program main.o util.o"]));

    auto batches = resolveDependencies(g, "program");

    // Expected: [[main.c, util.c], [main.o, util.o], [program]]
    assert(batches.length == 3);
    assert(batches[0].length == 2);
    assert(batches[1].length == 2);
    assert(batches[2].length == 1);
    assert(batches[2][0].name == "program");

    // Leaf batch can be in any order, but both leaves must be present.
    bool hasMainC, hasUtilC;
    foreach (t; batches[0])
    {
        if (t.name == "main.c") hasMainC = true;
        if (t.name == "util.c") hasUtilC = true;
    }
    assert(hasMainC && hasUtilC);
}

/// Regression: missing target returns empty.
unittest
{
    DependencyGraph g;
    auto batches = resolveDependencies(g, "nonexistent");
    assert(batches.length == 0);
}

/// Regression: external prerequisite (not in graph) is treated as already
/// satisfied and does not contribute to in-degree.
unittest
{
    DependencyGraph g;
    // main.o depends on main.c, but main.c is NOT in the graph
    g.addTarget(Target("main.o", TargetKind.file, ["main.c"], ["gcc -c main.c"]));
    g.addTarget(Target("program", TargetKind.file, ["main.o"], ["gcc -o program main.o"]));

    auto batches = resolveDependencies(g, "program");
    // main.c is external → main.o has effective in-degree 0
    // Expected: [[main.o], [program]]
    assert(batches.length == 2);
    assert(batches[0].length == 1);
    assert(batches[0][0].name == "main.o");
    assert(batches[1].length == 1);
    assert(batches[1][0].name == "program");
}

/// Critical path weights: program(1) → main.o(1) → main.c(0) = 2
unittest
{
    DependencyGraph g;
    g.addTarget(Target("main.c", TargetKind.file, [], []));
    g.addTarget(Target("main.o", TargetKind.file, ["main.c"],
        ["gcc -c main.c"]));
    g.addTarget(Target("program", TargetKind.file, ["main.o"],
        ["gcc -o program main.o"]));

    g.buildReverseEdges();
    computeCriticalWeights(g, "program");

    // main.c: no recipe, no prereqs → weight 0
    auto mc = g.findTarget("main.c");
    assert(mc !is null);
    assert(mc.criticalWeight == 0);

    // main.o: 1 recipe line, prereq main.c (weight 0) → weight 1
    auto mo = g.findTarget("main.o");
    assert(mo !is null);
    assert(mo.criticalWeight == 1);

    // program: 1 recipe line, prereq main.o (weight 1) → weight 2
    auto prog = g.findTarget("program");
    assert(prog !is null);
    assert(prog.criticalWeight == 2);
}

/// Diamond dependency: root → a, b → leaf. Weights should reflect
/// that both branches are equal.
unittest
{
    DependencyGraph g;
    g.addTarget(Target("leaf", TargetKind.file, [], ["touch leaf"]));          // weight 1
    g.addTarget(Target("a", TargetKind.file, ["leaf"], ["cp leaf a"]));        // weight 2
    g.addTarget(Target("b", TargetKind.file, ["leaf"], ["cp leaf b"]));        // weight 2
    g.addTarget(Target("root", TargetKind.file, ["a", "b"], ["cat a b"]));     // weight 3

    g.buildReverseEdges();
    computeCriticalWeights(g, "root");

    assert(g.findTarget("leaf").criticalWeight == 1);
    assert(g.findTarget("a").criticalWeight == 2);
    assert(g.findTarget("b").criticalWeight == 2);
    assert(g.findTarget("root").criticalWeight == 3);
}
