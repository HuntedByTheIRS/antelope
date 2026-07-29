/// Dependency graph construction from parsed rules.
module antelope.build.graph;

import antelope.parser.ast;
import antelope.build.target;
import antelope.diagnostics.errors;

/// A directed graph of target → prerequisite relationships.
struct DependencyGraph
{
    Target[] targets;              /// All known targets.
    string[string] variables;      /// Parsed variable assignments.
    AntelopeError[] cycleErrors;   /// Cycle detection results.
    bool[string] phonyTargets;     /// Names marked as .PHONY.

    /// Build and return the dependency graph from the AST.
    static DependencyGraph fromAst(AstNode root)
    {
        DependencyGraph graph;

        // Walk top-level rule_list children: rules, variable assignments,
        // directives, etc.
        foreach (child; root.children)
        {
            final switch (child.type)
            {
                case AstType.rule:
                    graph.addRuleFromAst(child);
                    break;
                case AstType.variable_assignment:
                    // data holds "name=value" — store for later expansion
                    graph.parseVariableAssignment(child.data);
                    break;
                case AstType.directive:
                    // Directives (include, vpath, etc.) are handled
                    // by the evaluator layer — skip for now.
                    break;
                case AstType.rule_list:
                    // Nested rule_list (e.g., from include merging).
                    // Recurse into it.
                    foreach (nested; child.children)
                    {
                        if (nested.type == AstType.rule)
                            graph.addRuleFromAst(nested);
                        else if (nested.type == AstType.variable_assignment)
                            graph.parseVariableAssignment(nested.data);
                    }
                    break;
                case AstType.prerequisite:
                case AstType.recipe_line:
                case AstType.function_call:
                    // Should not appear as direct children of rule_list.
                    break;
            }
        }

        // .PHONY handling: mark its prerequisites as phony targets
        graph.handlePhony();

        // .WAIT handling: split prerequisite groups with barriers
        graph.handleWait();

        // .JOBS handling: per-target job limits (native mode)
        graph.handleJobs();

        // Cycle detection: DFS with three-color marking
        graph.detectCycles();

        return graph;
    }

    /// Add a target to the graph.
    void addTarget(Target t)
    {
        targets ~= t;
    }

    /// Find a target by name. Returns null if not found.
    Target* findTarget(string name)
    {
        foreach (ref t; targets)
            if (t.name == name) return &t;
        return null;
    }

    /// Check if a target exists in the graph.
    bool hasTarget(string name)
    {
        return findTarget(name) !is null;
    }

private:
    /// Extract target name, prerequisites, and recipe from a rule AST node.
    void addRuleFromAst(AstNode ruleNode)
    {
        string targetName = ruleNode.data;
        string[] prereqs;
        string[] recipe;

        foreach (child; ruleNode.children)
        {
            if (child.type == AstType.prerequisite)
                prereqs ~= child.data;
            else if (child.type == AstType.recipe_line)
                recipe ~= child.data;
        }

        Target t;
        t.name = targetName;
        t.kind = TargetKind.file;
        t.prerequisites = prereqs;
        t.recipe = recipe;
        addTarget(t);
    }

    /// Parse a "name=value" variable assignment string into the variables map.
    void parseVariableAssignment(string data)
    {
        import std.string : indexOf;
        auto eq = data.indexOf('=');
        if (eq > 0)
        {
            string name = data[0 .. eq];
            string value = data[eq + 1 .. $];
            variables[name] = value;
        }
    }

    // ── Public scheduling / special-target API ──────────────────────────
public:

    /// Find the ".PHONY" target (if it exists) and mark all of its
    /// prerequisites as phony targets.
    void handlePhony()
    {
        Target* phony = findTarget(".PHONY");
        if (phony is null)
            return;

        foreach (name; phony.prerequisites)
        {
            Target* t = findTarget(name);
            if (t !is null)
                t.kind = TargetKind.phony;
            phonyTargets[name] = true;
        }
    }

    /// Process .WAIT special target: split prerequisite groups with barriers.
    ///
    /// Syntax: `target: group1 .WAIT group2`
    /// → group1 completes first, then group2 starts.
    /// Adds implicit dependencies: each group2 target depends on each group1 target.
    void handleWait()
    {
        foreach (ref t; targets)
        {
            ptrdiff_t waitPos = -1;
            foreach (i, p; t.prerequisites)
            {
                if (p == ".WAIT")
                {
                    waitPos = cast(ptrdiff_t) i;
                    break;
                }
            }
            if (waitPos < 0)
                continue;

            string[] group1 = t.prerequisites[0 .. cast(size_t) waitPos];
            string[] group2 = t.prerequisites[cast(size_t) waitPos + 1 .. $];

            // Remove .WAIT from prerequisites.
            t.prerequisites = group1 ~ group2;

            // Add implicit deps: each group2 target depends on group1 targets.
            foreach (g2name; group2)
            {
                auto g2 = findTarget(g2name);
                if (g2 is null)
                    continue;
                foreach (g1name; group1)
                {
                    bool alreadyDepends;
                    foreach (p; g2.prerequisites)
                        if (p == g1name) { alreadyDepends = true; break; }
                    if (!alreadyDepends && g1name != g2.name)
                        g2.prerequisites ~= g1name;
                }
            }
        }
    }

    /// Process .JOBS special target (native mode).
    ///
    /// Syntax: `.JOBS: N target1 target2 ...`
    /// Limits the named targets to at most N concurrent jobs.
    void handleJobs()
    {
        import std.conv : to;

        Target* jobsTarget = findTarget(".JOBS");
        if (jobsTarget is null)
            return;

        if (jobsTarget.prerequisites.length < 2)
            return;

        size_t limit;
        try
        {
            limit = jobsTarget.prerequisites[0].to!size_t;
        }
        catch (Exception)
        {
            return;
        }

        foreach (i, name; jobsTarget.prerequisites[1 .. $])
        {
            auto tp = findTarget(name);
            if (tp !is null)
                tp.jobLimit = limit;
        }

        jobsTarget.kind = TargetKind.phony;
        phonyTargets[".JOBS"] = true;
    }

    /// Build reverse edges: populate `dependents` for each target.
    /// For each target, scan all other targets' prerequisites and
    /// add this target's name to the dependents list of each prereq.
    void buildReverseEdges()
    {
        // Clear existing reverse edges.
        foreach (ref t; targets)
            t.dependents = [];

        foreach (ref t; targets)
        {
            foreach (prereq; t.prerequisites ~ t.orderOnlyPrereqs)
            {
                auto tp = findTarget(prereq);
                if (tp !is null)
                    tp.dependents ~= t.name;
            }
        }
    }

    /// Reset all scheduling state to defaults.
    /// NOTE: jobLimit is NOT reset — it is set by handleJobs() and persists
    /// across builds.
    void resetSchedulingState()
    {
        foreach (ref t; targets)
        {
            t.state = BuildState.pending;
            t.remainingDeps = 0;
            t.criticalWeight = 0;
        }
    }

    /// Compute remaining in-graph prerequisite count for each target.
    /// Stores the count in each target's `remainingDeps` field.
    /// Only counts prerequisites that exist as graph targets.
    void computeRemainingDeps()
    {
        foreach (ref t; targets)
        {
            size_t count;
            foreach (prereq; t.prerequisites ~ t.orderOnlyPrereqs)
            {
                if (hasTarget(prereq))
                    count++;
            }
            t.remainingDeps = count;
        }
    }

    /// Compute the transitive closure of a root target.
    /// Returns all target names reachable from root (including root itself).
    string[] transitiveClosure(string root)
    {
        bool[string] visited;
        string[] stack = [root];
        string[] result;

        while (stack.length > 0)
        {
            string current = stack[$ - 1];
            stack = stack[0 .. $ - 1];

            if (current in visited)
                continue;
            visited[current] = true;
            result ~= current;

            auto tp = findTarget(current);
            if (tp is null)
                continue;

            foreach (prereq; tp.prerequisites ~ tp.orderOnlyPrereqs)
            {
                if (hasTarget(prereq) && prereq !in visited)
                    stack ~= prereq;
            }
        }

        return result;
    }

    /// Detect cycles in the dependency graph using three-color DFS.
    /// Stores found cycles as AntelopeError in cycleErrors.
    void detectCycles()
    {
        // Three colors for DFS state.
        enum Color : ubyte { white, gray, black }

        // Adjacency list: target name → prerequisite names.
        string[][string] adjacency;
        foreach (t; targets)
            adjacency[t.name] = t.prerequisites;

        Color[string] colors;  // Default-initialized to white (0).
        string[] stack;        // Current DFS path for cycle reporting.

        // Recursive DFS visit; returns true if a cycle was found.
        bool dfsVisit(string node)
        {
            colors[node] = Color.gray;
            stack ~= node;

            auto depsPtr = node in adjacency;
            if (depsPtr)
            {
                foreach (dep; *depsPtr)
                {
                    Color* cPtr = dep in colors;

                    if (cPtr is null || *cPtr == Color.white)
                    {
                        // Not yet visited — descend.
                        if (dfsVisit(dep))
                            return true;
                    }
                    else if (*cPtr == Color.gray)
                    {
                        // Back-edge found — construct cycle description.
                        // Find where `dep` first appears in stack.
                        import std.string : join;
                        ptrdiff_t cycleStart = -1;
                        foreach (i, s; stack)
                        {
                            if (s == dep)
                            {
                                cycleStart = cast(ptrdiff_t) i;
                                break;
                            }
                        }
                        string[] cyclePath = stack[cast(size_t) cycleStart .. $];
                        cyclePath ~= dep; // Close the loop.

                        string cycleMsg = "cycle: " ~ cyclePath.join(" \u2192 ");
                        cycleErrors ~= AntelopeError(
                            ErrorKind.cyclicDependency,
                            cycleMsg,
                            "", 0, 0
                        );
                        return true;
                    }
                    // black nodes are already fully processed — ignore.
                }
            }

            colors[node] = Color.black;
            stack = stack[0 .. $ - 1]; // Pop.
            return false;
        }

        foreach (t; targets)
        {
            if (!(t.name in colors))
                dfsVisit(t.name);
        }
    }
}

// ─── Unittests ───────────────────────────────────────────────────────────

// Two-rule graph with no cycles.
unittest
{
    // AST:    all: program
    //             ./program
    //         program: main.o
    //             cc -o program main.o

    auto all = AstNode(AstType.rule, [], "all");
    all.children ~= AstNode(AstType.prerequisite, [], "program");
    all.children ~= AstNode(AstType.recipe_line, [], "./program");

    auto program = AstNode(AstType.rule, [], "program");
    program.children ~= AstNode(AstType.prerequisite, [], "main.o");
    program.children ~= AstNode(AstType.recipe_line, [], "cc -o program main.o");

    auto root = AstNode(AstType.rule_list, [all, program], "");

    auto graph = DependencyGraph.fromAst(root);

    assert(graph.targets.length == 2);
    assert(graph.hasTarget("all"));
    assert(graph.hasTarget("program"));

    auto allTarget = graph.findTarget("all");
    assert(allTarget !is null);
    assert(allTarget.prerequisites == ["program"]);
    assert(allTarget.recipe == ["./program"]);

    // No cycles expected.
    assert(graph.cycleErrors.length == 0);
}

// Cycle detection: a → b → c → a.
unittest
{
    // AST:    a: b
    //         b: c
    //         c: a

    auto a = AstNode(AstType.rule, [], "a");
    a.children ~= AstNode(AstType.prerequisite, [], "b");

    auto b = AstNode(AstType.rule, [], "b");
    b.children ~= AstNode(AstType.prerequisite, [], "c");

    auto c = AstNode(AstType.rule, [], "c");
    c.children ~= AstNode(AstType.prerequisite, [], "a");

    auto root = AstNode(AstType.rule_list, [a, b, c], "");

    auto graph = DependencyGraph.fromAst(root);

    // Graph should still be built with 3 targets.
    assert(graph.targets.length == 3);

    // Cycle must be detected.
    assert(graph.cycleErrors.length > 0);
    assert(graph.cycleErrors[0].kind == ErrorKind.cyclicDependency);
}

// .PHONY handling: mark prerequisites as phony.
unittest
{
    // AST:    .PHONY: clean
    //         clean:
    //             rm -f *.o

    auto phony = AstNode(AstType.rule, [], ".PHONY");
    phony.children ~= AstNode(AstType.prerequisite, [], "clean");

    auto clean = AstNode(AstType.rule, [], "clean");
    clean.children ~= AstNode(AstType.recipe_line, [], "rm -f *.o");

    auto root = AstNode(AstType.rule_list, [phony, clean], "");

    auto graph = DependencyGraph.fromAst(root);

    assert(graph.targets.length == 2);

    auto cleanTarget = graph.findTarget("clean");
    assert(cleanTarget !is null);
    assert(cleanTarget.kind == TargetKind.phony);
}
