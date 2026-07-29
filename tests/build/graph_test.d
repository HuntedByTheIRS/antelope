/// Unit tests for the dependency graph construction.
///
/// Tests DAG building from AST rules, cycle detection, and
/// topological ordering.
module antelope.tests.build.graph_test;

import antelope.build.graph;
import antelope.build.target;

/// Test constructing a simple linear dependency graph.
unittest
{
    Target[] targets = [
        Target("all", TargetKind.phony, ["hello"], []),
        Target("hello", TargetKind.file, ["hello.o"], []),
        Target("hello.o", TargetKind.file, ["hello.c"], []),
        Target("hello.c", TargetKind.file, [], []),
    ];

    auto graph = DependencyGraph.fromTargets(targets);
    assert(graph.nodes.length == 4);
}

/// Test cycle detection.
unittest
{
    Target[] targets = [
        Target("a", TargetKind.file, ["b"], []),
        Target("b", TargetKind.file, ["c"], []),
        Target("c", TargetKind.file, ["a"], []),
    ];

    auto graph = DependencyGraph.fromTargets(targets);
    assert(graph.hasCycle());
}
