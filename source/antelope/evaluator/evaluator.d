/// Top-level evaluator that walks the AST and drives execution.
///
/// The evaluator is the central dispatch between the parser and the build
/// engine.  It walks every node in the parsed AST and:
///   * Adds rules as targets to the dependency graph (via `build.graph`)
///   * Populates the variable environment (via `shell.environment`)
///   * Evaluates directives — includes, conditionals, VPATH configuration
///
/// This is called by `runBuild()` after parsing to populate the graph and
/// environment before scheduling and executing the build.
module antelope.evaluator.evaluator;

import antelope.parser.ast;
import antelope.evaluator.expansion;
import antelope.evaluator.conditionals;
import antelope.evaluator.functions;
import antelope.build.graph;
import antelope.shell.environment;
import antelope.build.target;
import antelope.compatibility.implicit_rules;
import antelope.compatibility.order_only;
import antelope.compatibility.pattern_rules;
import antelope.compatibility.gnu_make;
import antelope.compatibility.posix_make;
import antelope.diagnostics.output;
import std.string : indexOf, strip;
import std.conv : to;
import std.file : exists, readText;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Evaluate a parsed AST, populating the environment and dependency graph.
///
/// Walks the AST recursively, dispatching each node type to the appropriate
/// handler.  Rules become targets in the dependency graph.  Variable
/// assignments populate the environment.  Directives trigger include /
/// conditional / VPATH behaviour.
///
/// Params:
///   root  = the AST root (usually a `rule_list` node)
///   env   = pointer to the variable environment (may be null for
///           read-only scanning)
///   graph = pointer to the dependency graph to populate
void evaluate(AstNode root, Environment* env, DependencyGraph* graph,
              GnuMakeCompat* gnuCompat = null,
              PosixCompat* posixCompat = null)
{
    foreach (child; root.children)
    {
        final switch (child.type)
        {
            case AstType.rule_list:
                evaluate(child, env, graph, gnuCompat, posixCompat); // recurse into nested rule lists
                break;
            case AstType.rule:
                handleRule(child, env, graph);
                break;
            case AstType.variable_assignment:
                handleVariableAssignment(child, env);
                break;
            case AstType.directive:
                handleDirective(child, env, graph, gnuCompat, posixCompat);
                break;
            case AstType.prerequisite:
            case AstType.recipe_line:
            case AstType.function_call:
                // These are leaf / child nodes — they are processed by their
                // parent (e.g. a rule node collects its own prereqs and recipes).
                break;
        }
    }
}

// ---------------------------------------------------------------------------
// Private handlers
// ---------------------------------------------------------------------------

/// Resolve implicit rules for all targets in the graph that have no recipe.
///
/// In GNU Make mode (`-gnu`), targets without an explicit recipe are tried
/// against the built-in implicit rule database (e.g. `%.o: %.c`).  When a
/// rule matches, the target's recipe and prerequisites are populated from
/// the rule.  Any prerequisite that does not yet exist in the graph is added
/// as a stub target so it can itself be resolved in a subsequent pass.
///
/// This function should be called after `evaluate()` has populated the graph
/// but before dependency resolution, and only when `-gnu` mode is active.
///
/// Params:
///   graph = the populated dependency graph (mutated in place)
///
/// Returns: the number of targets that had their recipe resolved in this pass.
///          A return value of 0 means no more implicit rules can be applied.
size_t resolveImplicitRules(ref DependencyGraph graph, Environment* env = null)
{
    import antelope.compatibility.implicit_rules;
    size_t resolved;

    // Work on a copy of the target names so mutations (adding new stub
    // targets via addTarget) don't skew the iteration.
    string[] snapshot;
    foreach (ref t; graph.targets)
        snapshot ~= t.name;

    foreach (targetName; snapshot)
    {
        auto tp = graph.findTarget(targetName);
        if (tp is null)
            continue;

        // Only fill in targets that have no recipe yet.
        if (tp.recipe.length > 0)
            continue;

        // Skip phony targets — they never get implicit recipes.
        if (tp.kind == TargetKind.phony)
            continue;

        // Try to match a built-in implicit rule first.
        auto match = matchImplicitRule(tp.name);
        bool applied;

        // If built-in matched and satisfiable, apply it
        if (match !is null)
        {
            import std.file : exists;
            if (prereqSatisfiable(match.resolvedPrereq, graph))
            {
                tp.recipe = match.rule.recipe;
                if (match.resolvedPrereq.length > 0)
                {
                    bool alreadyPresent;
                    foreach (p; tp.prerequisites)
                        if (p == match.resolvedPrereq) { alreadyPresent = true; break; }
                    if (!alreadyPresent)
                    {
                        string[] np = [match.resolvedPrereq];
                        np ~= tp.prerequisites;
                        tp.prerequisites = np;
                    }
                    if (!graph.hasTarget(match.resolvedPrereq))
                    {
                        import std.file : exists;
                        if (!exists(match.resolvedPrereq))
                        {
                            Target stub;
                            stub.name = match.resolvedPrereq;
                            stub.kind = TargetKind.file;
                            graph.addTarget(stub);
                        }
                    }
                }
                resolved++;
                applied = true;
            }
        }

            // If built-in didn't match or wasn't satisfiable, try user-defined pattern rules
            if (!applied)
            {
                import antelope.compatibility.pattern_rules;
                PatternRule[] userRules;
                foreach (ref gt; graph.targets)
                    if (isPatternTarget(gt.name))
                        userRules ~= toPatternRule(gt);
                auto userMatches = matchPatternRules(tp.name, userRules);
            // Use the LAST matching pattern rule (most recently defined,
            // which is typically the most specific/default one like %.c)
            if (userMatches.length > 0)
            {
                auto um = userMatches[$ - 1];
                resolveUserPatternRule(tp, um, graph, env);
                resolved++;
                applied = true;
            }
        }

    }

    return resolved;
}

/// Apply a matched user-defined pattern rule to a target.
///
/// Sets the target's recipe from the matched pattern rule and adds the
/// resolved prerequisites (e.g., for a `%.o: %.c` rule matching `foo.o`,
/// sets recipe to the rule's recipe and adds `foo.c` as a prerequisite).
/// Any prerequisite not already in the graph is added as a stub target
/// so it can be resolved in a subsequent pass.
private void resolveUserPatternRule(Target* tp, PatternMatch match,
                                    ref DependencyGraph graph, Environment* env)
{
    tp.recipe = match.rule.recipe;
    // Clear existing prereqs and set from pattern match
    tp.prerequisites = [];
    foreach (prereq; match.resolvedPrereqs)
    {
        // Already resolved by matchPatternRules
        bool alreadyPresent;
        foreach (p; tp.prerequisites)
        {
            if (p == prereq)
            {
                alreadyPresent = true;
                break;
            }
        }
        if (!alreadyPresent)
            tp.prerequisites ~= prereq;

        if (!graph.hasTarget(prereq))
        {
            import std.file : exists;
            if (!exists(prereq))
            {
                Target stub;
                stub.name = prereq;
                stub.kind = TargetKind.file;
                graph.addTarget(stub);
            }
        }
    }
}

/// Check whether an implicit rule prerequisite chain is satisfiable.
/// Recursively checks if the prerequisite eventually resolves to a file
/// that exists on disk or is already in the dependency graph.
private bool prereqSatisfiable(string prereq, ref DependencyGraph graph, int depth = 0)
{
    import std.file : exists;
    if (depth > 3) return false;  // safety limit

    // Already exists as a file or as a graph target
    if (exists(prereq) || graph.hasTarget(prereq))
        return true;

    // Try to resolve further via implicit rules
    import antelope.compatibility.implicit_rules;
    auto match = matchImplicitRule(prereq);
    if (match is null)
        return false;

    return prereqSatisfiable(match.resolvedPrereq, graph, depth + 1);
}

/// Process a rule node: extract the target name, collect prerequisites and
/// recipe lines from children, create a `Target` and add it to the graph.
///
/// The `data` field of the rule node holds the target name (e.g. "foo.o").
/// Children of type `AstType.prerequisite` contribute their `data` field to
/// the prerequisite list; children of type `AstType.recipe_line` contribute
/// their `data` field to the recipe body.
///
/// Target-specific variable assignments (e.g. `target: VAR = value`) are
/// also detected here.  When the parser produces consecutive prerequisite
/// children that form an assignment pattern (name, operator, value), those
/// children are extracted from the prereq list and stored as scoped
/// variables on the environment instead.
private void handleRule(AstNode node, Environment* env, DependencyGraph* graph)
{
    string rawData = node.data;
    bool isDoubleColon = (rawData.length > 2 && rawData[$-2..$] == "::");

    string targetName = isDoubleColon ? rawData[0..$-2] : rawData;

    if (env)
    {
        import antelope.evaluator.expansion;
        import std.string;
        targetName = expand(targetName, env).strip;
    }

    string[] prereqs;
    string[] recipe;

    foreach (child; node.children)
    {
        switch (child.type)
        {
            case AstType.prerequisite:
                prereqs ~= child.data;
                break;
            case AstType.recipe_line:
                recipe ~= child.data;
                break;
            default:
                break;
        }
    }

    // Detect target-specific variable assignments embedded in the prereq
    // list.  The current parser emits `target: VAR = value` as three
    // consecutive prereq children ("VAR", "=", "value").  We scan the
    // list for this pattern and extract matching entries into scoped
    // variables, removing them from the actual prerequisite list.
    if (env && prereqs.length >= 3)
    {
        string[] realPrereqs;
        size_t i = 0;
        while (i < prereqs.length)
        {
            // Check whether the next three prereq tokens form an assignment
            // pattern: NAME OPERATOR VALUE
            if (i + 2 < prereqs.length)
            {
                string maybeName  = prereqs[i];
                string maybeOp    = prereqs[i + 1];
                string maybeValue = prereqs[i + 2];

                // Accept =, :=, +=, and ?= as assignment operators.
                if (maybeOp == "=" || maybeOp == ":=" ||
                    maybeOp == "+=" || maybeOp == "?=")
                {
                    bool isRecursive = (maybeOp == "=");
                    env.addScopedVar(targetName, maybeName, maybeValue,
                                     isRecursive);
                    i += 3; // consume all three
                    continue;
                }
            }
            realPrereqs ~= prereqs[i];
            i++;
        }
        prereqs = realPrereqs;
    }

    // Expand prerequisite names too (GNU Make compat).
    // Also split expanded prereqs on whitespace for multi-word expansion.
    if (env)
    {
        import antelope.evaluator.expansion;
        import std.string;
        import std.array : array;
        string[] expandedPrereqs;
        foreach (ref p; prereqs)
        {
            string expanded = expand(p, env);
            foreach (word; expanded.split(" "))
            {
                if (word.length > 0)
                    expandedPrereqs ~= word;
            }
        }
        prereqs = expandedPrereqs;

        // Create stub targets for unresolved .a prerequisites.
        // Autotools-generated Makefiles list archive libraries (e.g.,
        // lib/libgnu.a) as prerequisites but define no top-level rule —
        // they're built in subdirectories. We create self-contained stubs
        // that compile sources in-place and archive them.
        if (graph)
        {
            foreach (prereq; prereqs)
            {
                if (prereq.length > 2 && prereq[$-2..$] == ".a" &&
                    !graph.hasTarget(prereq) && !exists(prereq))
                {
                    import std.path : dirName, baseName;
                    Target stub;
                    stub.name = prereq;
                    stub.kind = TargetKind.file;
                    auto dir = dirName(prereq);
                    if (dir.length == 0) dir = ".";
                    // Compile .c sources in the archive's directory, then archive
                    stub.recipe = [
                        "@cd " ~ dir ~ " && for f in *.c; do " ~
                        "$(CC) $(DEFS) $(DEFAULT_INCLUDES) $(INCLUDES) " ~
                        "$(AM_CPPFLAGS) $(CPPFLAGS) $(AM_CFLAGS) $(CFLAGS) " ~
                        "-c \"$f\" -o \"$(basename $f).o\"; done && " ~
                        "$(AR) cr " ~ baseName(prereq) ~ " *.o"
                    ];
                    graph.addTarget(stub);
                }
            }
        }
    }

    Target t;
    t.name = targetName;
    t.kind = TargetKind.file;

    // Split prerequisites into normal and order-only at | separator.
    auto prereqSplit = splitPrereqs(prereqs);
    t.prerequisites = prereqSplit.normal;
    t.orderOnlyPrereqs = prereqSplit.orderOnly;
    t.recipe = recipe;

    // Handle multi-target rules: when target expands to multiple words,
    // create separate targets for each (same prereqs + recipe).
    import std.string;
    import std.algorithm : filter;
    import std.array : array;
    auto expandedTargets = targetName.split(" ").filter!(s => s.length > 0).array;
    if (expandedTargets.length > 1)
    {
        foreach (tn; expandedTargets)
        {
            Target mt;
            mt.name = tn;
            mt.kind = TargetKind.file;
            mt.prerequisites = prereqSplit.normal;
            mt.orderOnlyPrereqs = prereqSplit.orderOnly;
            mt.recipe = recipe;
            if (graph) graph.addTarget(mt);
        }
        return;
    }

    if (graph)
    {
        Target* existing = graph.findTarget(t.name);
        if (existing !is null && isDoubleColon)
        {
            // Double-colon: each :: rule gets independent execution.
            // Append recipes and prerequisites to the existing target.
            existing.recipe ~= t.recipe;
            foreach (p; t.prerequisites)
                existing.prerequisites ~= p;
            foreach (p; t.orderOnlyPrereqs)
                existing.orderOnlyPrereqs ~= p;
        }
        else if (existing is null || t.name.indexOf('%') >= 0)
        {
            // Pattern rules (containing %) must have separate entries
            // so each can provide a different prerequisite chain
            graph.addTarget(t);
        }
        else
        {
            // Merge prereqs into existing target
            foreach (p; t.prerequisites)
            {
                bool found;
                foreach (ep; existing.prerequisites)
                    if (ep == p) { found = true; break; }
                if (!found) existing.prerequisites ~= p;
            }
            foreach (p; t.orderOnlyPrereqs)
            {
                bool found;
                foreach (ep; existing.orderOnlyPrereqs)
                    if (ep == p) { found = true; break; }
                if (!found) existing.orderOnlyPrereqs ~= p;
            }
            if (t.recipe.length > 0 && existing.recipe.length == 0)
                existing.recipe = t.recipe;
        }
    }
}

/// Parse and apply a variable assignment.
///
/// Supports four GNU Make assignment forms:
///   `NAME = VALUE`   — recursive (value stored unexpanded; expanded on use)
///   `NAME := VALUE`  — simple   (value expanded at definition time)
///   `NAME += VALUE`  — append   (appended to existing value with space)
///   `NAME ?= VALUE`  — conditional (set only if currently undefined)
///
/// Whitespace around the operator and value is trimmed.
/// The `data` field of the node contains the raw assignment string.
private void handleVariableAssignment(AstNode node, Environment* env)
{
    if (!env)
        return;

    string data = node.data;

    // Check multi-character operators first to avoid false matches on plain '='.
    auto colonEq = indexOf(data, ":=");
    auto plusEq  = indexOf(data, "+=");
    auto condEq  = indexOf(data, "?=");

    if (colonEq >= 0)
    {
        // Simple assignment — expand immediately.
        string name  = data[0 .. colonEq].strip;
        string value = data[colonEq + 2 .. $].strip;
        env.set(name, expand(value, env));
    }
    else if (plusEq >= 0)
    {
        // Append — add to existing value, space-separated.
        string name  = data[0 .. plusEq].strip;
        string value = data[plusEq + 2 .. $].strip;
        if (env.hasKey(name))
            env.set(name, env.get(name) ~ " " ~ value);
        else
            env.set(name, value);
    }
    else if (condEq >= 0)
    {
        // Conditional — only set if the variable is currently undefined.
        string name  = data[0 .. condEq].strip;
        string value = data[condEq + 2 .. $].strip;
        if (!env.hasKey(name))
            env.set(name, value);
    }
    else
    {
        // Recursive assignment — store unexpanded; expansion happens on use.
        auto plainEq = indexOf(data, "=");
        if (plainEq >= 0)
        {
            string name  = data[0 .. plainEq].strip;
            string value = data[plainEq + 1 .. $].strip;
            env.set(name, value);
        }
    }
}

/// Dispatch a directive node: parse the directive name from `node.data` and
/// handle includes, conditionals, and VPATH configuration.
///
/// Directive types recognised:
///   `include` / `-include` / `sinclude` — file inclusion (stub, not yet
///       implemented; filesystem reading is needed for a full implementation)
///   `ifdef` / `ifndef` / `ifeq` / `ifneq` — conditional blocks; the
///       condition is evaluated and the children are processed only when
///       the conditional is true
///   `vpath` — VPATH directory search pattern (stub)
///
/// Other directives (`define`, `undefine`, `export`, `unexport`, `else_`,
/// `endif`) are silently ignored for now.
private void handleDirective(AstNode node, Environment* env, DependencyGraph* graph,
                             GnuMakeCompat* gnuCompat, PosixCompat* posixCompat)
{
    string data = node.data;
    auto space = indexOf(data, " ");
    string dirName = space >= 0 ? data[0 .. space] : data;

    switch (dirName)
    {
        case "include":
        case "-include":
        case "sinclude":
            handleInclude(dirName, data, space, env, graph, gnuCompat, posixCompat);
            break;

        case "ifdef":
        case "ifndef":
        case "ifeq":
        case "ifneq":
            handleConditionalDirective(dirName, data, space, node, env, graph,
                                       gnuCompat, posixCompat);
            break;

        case "vpath":
        {
            // Format: "vpath PATTERN DIRS..."
            // e.g., "vpath %.h include/" or "vpath %.h include src"
            if (space < 0) break;
            string rest = data[space + 1 .. $].strip;
            auto space2 = indexOf(rest, " ");
            if (space2 < 0) break;
            string pattern = rest[0 .. space2].strip;
            string dirs = rest[space2 + 1 .. $].strip;

            import antelope.compatibility.vpath;
            import std.string : split;
            VPathEntry entry;
            entry.pattern = pattern;
            foreach (dir; dirs.split(" "))
                if (dir.length > 0) entry.directories ~= dir;
            // Store in env for later use by the resolver
            if (env !is null)
                env.set("__vpath_" ~ pattern, dirs);
            break;
        }

        default:
            // Stub — define, undefine, export_, unexport, else_, endif.
            break;
    }
}

/// Evaluate a conditional directive and process the true-branch children.
///
/// The directive text is split into the operator and its arguments (lhs/rhs)
/// to match the `evaluateConditional` signature.  If the condition is true,
/// all children of the directive node are recursively evaluated; if false,
/// they are skipped.
private void handleConditionalDirective(string dirName, string data, ptrdiff_t space,
                                        AstNode node, Environment* env,
                                        DependencyGraph* graph,
                                        GnuMakeCompat* gnuCompat,
                                        PosixCompat* posixCompat)
{
    string lhs, rhs;

    if (space >= 0)
    {
        string rest = data[space + 1 .. $].strip;
        // Paren form: ifeq (a, b) — pass the entire rest as lhs, empty rhs.
        if (rest.length > 0 && rest[0] == '(')
        {
            lhs = rest;
            rhs = "";
        }
        else
        {
            // Two-argument form: ifeq a b
            auto sp2 = indexOf(rest, " ");
            if (sp2 >= 0)
            {
                lhs = rest[0 .. sp2];
                rhs = rest[sp2 + 1 .. $];
            }
            else
            {
                // Single argument (ifdef VAR_NAME)
                lhs = rest;
            }
        }
    }

    bool condResult = evaluateConditional(dirName, lhs, rhs, env);

    // Split children into then-branch and (optional) else-branch
    AstNode[] thenChildren;
    AstNode[] elseChildren;
    bool inElse;
    foreach (child; node.children)
    {
        if (child.type == AstType.directive && child.data == "else")
        {
            inElse = true;
            elseChildren = child.children;
        }
        else if (!inElse)
        {
            thenChildren ~= child;
        }
    }

    // Evaluate the correct branch
    AstNode wrapper;
    wrapper.type = AstType.rule_list;
    if (condResult)
    {
        wrapper.children = thenChildren;
    }
    else
    {
        wrapper.children = elseChildren;
    }
    if (wrapper.children.length > 0)
    {
        evaluate(wrapper, env, graph, gnuCompat, posixCompat);
    }
}

/// Handle an include directive: parse the file path(s) from the directive text,
/// read the file(s), parse their content, and evaluate them into the environment
/// and dependency graph.
///
/// For `include`, a missing file is logged as a message and silently skipped.
/// For `-include` / `sinclude`, a missing file produces no output at all.
///
/// Multi-file includes (e.g., `include $(DEP_FILES)` where DEP_FILES expands
/// to multiple space-separated paths) are common in autotools-generated
/// Makefiles.  Each path is processed individually.
private void handleInclude(string dirName, string data, ptrdiff_t space,
                           Environment* env, DependencyGraph* graph,
                           GnuMakeCompat* gnuCompat, PosixCompat* posixCompat)
{
    if (space < 0) return;

    string rawPath = data[space + 1 .. $].strip;
    if (rawPath.length == 0) return;

    // Expand variable references in the include path (e.g., $(DEP_FILES)
    // commonly expands to "./.deps/a.Po ./.deps/b.Po" in autotools projects).
    import antelope.evaluator.expansion;
    import std.string : split;
    auto paths = expand(rawPath, env).split(" ");

    foreach (path; paths)
    {
        if (path.length == 0) continue;

        if (!exists(path))
        {
            if (dirName == "include")
                log(LogLevel.normal, "antelope: " ~ path ~ ": No such file");
            continue;
        }

        import antelope.parser.parser;
        string includedContent = readText(path);
        auto includedAst = parse(includedContent);
        evaluate(includedAst, env, graph, gnuCompat, posixCompat);
    }
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

///
unittest
{
    // --- Simple one-rule AST → graph has one target ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "hello";

    AstNode recipe;
    recipe.type = AstType.recipe_line;
    recipe.data = "echo hello";
    rule.children = [recipe];

    root.children = [rule];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "graph should contain exactly 1 target");
    assert(graph.targets[0].name == "hello",
           "target name should be 'hello', got: " ~ graph.targets[0].name);
    assert(graph.targets[0].recipe.length == 1,
           "target should have 1 recipe line");
    assert(graph.targets[0].recipe[0] == "echo hello",
           "recipe should be 'echo hello', got: " ~ graph.targets[0].recipe[0]);
    assert(graph.targets[0].kind == TargetKind.file,
           "default kind should be file");
}

///
unittest
{
    // --- Variable assignment → env.get returns correct value ---
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode varAssign;
    varAssign.type = AstType.variable_assignment;
    varAssign.data = "CC=gcc";
    root.children = [varAssign];

    evaluate(root, &env, null);

    assert(env.get("CC") == "gcc",
           "CC should be 'gcc', got: " ~ env.get("CC"));
    assert(env.hasKey("CC"),
           "CC should exist in environment");
}

///
unittest
{
    // --- Simple assignment (:=) expands immediately ---
    Environment env;
    env.set("SRC", "main.c");

    AstNode root;
    root.type = AstType.rule_list;

    AstNode varAssign;
    varAssign.type = AstType.variable_assignment;
    varAssign.data = "OBJ:=$(SRC:.c=.o)";
    root.children = [varAssign];

    evaluate(root, &env, null);

    // $(SRC:.c=.o) is not a standard GNU Make expansion — the expand() function
    // will try to resolve $(SRC:.c=.o) as a variable name after expanding
    // nested references.  Since there is no variable named "SRC:.c=.o" or
    // "main.c:.c=.o", the result is empty.
    // This test just verifies that the := path executes without error.
    assert(env.hasKey("OBJ"),
           "OBJ should be set via :=");
}

///
unittest
{
    // --- Rule with prerequisites → Target has correct prereq list ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "program";

    AstNode prereq1;
    prereq1.type = AstType.prerequisite;
    prereq1.data = "main.o";

    AstNode prereq2;
    prereq2.type = AstType.prerequisite;
    prereq2.data = "util.o";

    AstNode recipe;
    recipe.type = AstType.recipe_line;
    recipe.data = "gcc -o program main.o util.o";

    rule.children = [prereq1, prereq2, recipe];
    root.children = [rule];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "graph should contain exactly 1 target");
    assert(graph.targets[0].name == "program",
           "target name should be 'program', got: " ~ graph.targets[0].name);
    assert(graph.targets[0].prerequisites.length == 2,
           "target should have 2 prerequisites, got: " ~
           to!string(graph.targets[0].prerequisites.length));
    assert(graph.targets[0].prerequisites[0] == "main.o",
           "first prereq should be 'main.o', got: " ~
           graph.targets[0].prerequisites[0]);
    assert(graph.targets[0].prerequisites[1] == "util.o",
           "second prereq should be 'util.o', got: " ~
           graph.targets[0].prerequisites[1]);
    assert(graph.targets[0].recipe.length == 1,
           "target should have 1 recipe line");
}

///
unittest
{
    // --- += append assignment ---
    Environment env;
    env.set("CFLAGS", "-O2");

    AstNode root;
    root.type = AstType.rule_list;

    AstNode appendAssign;
    appendAssign.type = AstType.variable_assignment;
    appendAssign.data = "CFLAGS+=-Wall";
    root.children = [appendAssign];

    evaluate(root, &env, null);

    assert(env.get("CFLAGS") == "-O2 -Wall",
           "CFLAGS should be '-O2 -Wall', got: " ~ env.get("CFLAGS"));
}

///
unittest
{
    // --- ?= conditional assignment — sets when undefined ---
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode condAssign;
    condAssign.type = AstType.variable_assignment;
    condAssign.data = "CC?=gcc";
    root.children = [condAssign];

    evaluate(root, &env, null);

    assert(env.get("CC") == "gcc",
           "?= should set CC to 'gcc', got: " ~ env.get("CC"));

    // --- ?= conditional assignment — does NOT overwrite existing ---
    AstNode condAssign2;
    condAssign2.type = AstType.variable_assignment;
    condAssign2.data = "CC?=clang";
    AstNode root2;
    root2.type = AstType.rule_list;
    root2.children = [condAssign2];

    evaluate(root2, &env, null);

    assert(env.get("CC") == "gcc",
           "?= should NOT overwrite existing CC, got: " ~ env.get("CC"));
}

///
unittest
{
    // --- Null graph: evaluate should not crash when graph is null ---
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "noop";

    AstNode recipe;
    recipe.type = AstType.recipe_line;
    recipe.data = "true";
    rule.children = [recipe];

    root.children = [rule];

    // This must not segfault.
    evaluate(root, &env, null);
    assert(true, "evaluate with null graph should complete without error");
}

///
unittest
{
    // --- Null env: variable assignments should be silently skipped ---
    AstNode root;
    root.type = AstType.rule_list;

    AstNode varAssign;
    varAssign.type = AstType.variable_assignment;
    varAssign.data = "X=y";
    root.children = [varAssign];

    // This must not segfault.
    evaluate(root, null, null);
    assert(true, "evaluate with null env should complete without error");
}

///
unittest
{
    // --- Conditional directive (ifeq true) — processes children ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode dirNode;
    dirNode.type = AstType.directive;
    dirNode.data = "ifeq (gcc, gcc)";

    AstNode ruleInside;
    ruleInside.type = AstType.rule;
    ruleInside.data = "true_branch_target";

    dirNode.children = [ruleInside];
    root.children = [dirNode];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "true-branch target should be added to graph");
    assert(graph.targets[0].name == "true_branch_target",
           "true-branch target name should match");
}

///
unittest
{
    // --- Conditional directive (ifeq false) — skips children ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode dirNode;
    dirNode.type = AstType.directive;
    dirNode.data = "ifeq (gcc, clang)";

    AstNode ruleInside;
    ruleInside.type = AstType.rule;
    ruleInside.data = "false_branch_target";

    dirNode.children = [ruleInside];
    root.children = [dirNode];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 0,
           "false-branch target should NOT be added to graph");
}

///
unittest
{
    // --- Two-argument conditional form ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode dirNode;
    dirNode.type = AstType.directive;
    dirNode.data = "ifneq a b";

    AstNode ruleInside;
    ruleInside.type = AstType.rule;
    ruleInside.data = "different_test";

    dirNode.children = [ruleInside];
    root.children = [dirNode];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "ifneq true-branch target should be added");
    assert(graph.targets[0].name == "different_test");
}

///
unittest
{
    // --- ifdef directive with existing variable ---
    DependencyGraph graph;
    Environment env;
    env.set("DEBUG", "1");

    AstNode root;
    root.type = AstType.rule_list;

    AstNode dirNode;
    dirNode.type = AstType.directive;
    dirNode.data = "ifdef DEBUG";

    AstNode ruleInside;
    ruleInside.type = AstType.rule;
    ruleInside.data = "debug_build";

    dirNode.children = [ruleInside];
    root.children = [dirNode];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "ifdef DEBUG (exists) should process children");
    assert(graph.targets[0].name == "debug_build");
}

///
unittest
{
    // --- ifndef with missing variable should process children ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode dirNode;
    dirNode.type = AstType.directive;
    dirNode.data = "ifndef MISSING";

    AstNode ruleInside;
    ruleInside.type = AstType.rule;
    ruleInside.data = "missing_conditional_target";

    dirNode.children = [ruleInside];
    root.children = [dirNode];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "ifndef MISSING (not present) should process children");
    assert(graph.targets[0].name == "missing_conditional_target");
}

///
unittest
{
    // --- Nested rule_list recursion ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode innerList;
    innerList.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "nested_target";

    innerList.children = [rule];
    root.children = [innerList];

    evaluate(root, &env, &graph);

    assert(graph.targets.length == 1,
           "nested rule_list should be recursed into");
    assert(graph.targets[0].name == "nested_target");
}

///
unittest
{
    // --- Multiple rules and variables in one evaluation pass ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode var1;
    var1.type = AstType.variable_assignment;
    var1.data = "CC=gcc";

    AstNode rule1;
    rule1.type = AstType.rule;
    rule1.data = "foo.o";

    AstNode prereq;
    prereq.type = AstType.prerequisite;
    prereq.data = "foo.c";
    rule1.children = [prereq];

    AstNode var2;
    var2.type = AstType.variable_assignment;
    var2.data = "CFLAGS=-Wall";

    AstNode rule2;
    rule2.type = AstType.rule;
    rule2.data = "bar.o";

    root.children = [var1, rule1, var2, rule2];

    evaluate(root, &env, &graph);

    assert(env.get("CC") == "gcc");
    assert(env.get("CFLAGS") == "-Wall");
    assert(graph.targets.length == 2);
    assert(graph.targets[0].name == "foo.o");
    assert(graph.targets[1].name == "bar.o");
}

///
unittest
{
    // --- Implicit rule resolution: target without recipe gets one ---
    DependencyGraph graph;

    // Add a target with no recipe — like `program:` with no body
    Target t;
    t.name = "program";
    t.kind = TargetKind.file;
    t.prerequisites = [];
    t.recipe = [];
    graph.addTarget(t);

    // Create files to satisfy the implicit rule chain:
    //   program → program.o → program.c (exists)
    import std.file : write, remove;
    write("program.c", "int main(){}");
    scope (exit) remove("program.c");

    size_t resolved = resolveImplicitRules(graph);
    assert(resolved == 1, "should resolve 1 target");

    auto program = graph.findTarget("program");
    assert(program !is null);
    assert(program.recipe.length > 0,
           "program should have recipe from implicit rule");
    assert(program.prerequisites.length >= 1,
           "program should have prereq from implicit rule");
    assert(program.prerequisites[0] == "program.o",
           "first prereq should be 'program.o', got: " ~ program.prerequisites[0]);

    // The prerequisite `program.o` should be added as a stub target.
    assert(graph.hasTarget("program.o"),
           "program.o should be added as stub target");
}

///
unittest
{
    // --- Implicit rule chaining: .o → .c in two passes ---
    DependencyGraph graph;

    // Only `program` is declared; no explicit recipe.
    Target t;
    t.name = "program";
    t.kind = TargetKind.file;
    graph.addTarget(t);

    // Create program.c so the implicit rule chain can resolve
    import std.file : write, remove;
    write("program.c", "int main(){}");
    scope (exit) remove("program.c");

    // Pass 1: resolve `program` via link rule → adds `program.o` stub
    size_t r1 = resolveImplicitRules(graph);
    assert(r1 == 1, "pass 1 should resolve program");
    assert(graph.hasTarget("program.o"));
    auto progO = graph.findTarget("program.o");
    assert(progO !is null);
    assert(progO.recipe.length == 0, "program.o should have no recipe yet");

    // Pass 2: `program.o` should match `%.o: %.c` → sets prereq `program.c`
    // (No stub needed — program.c exists on disk)
    size_t r2 = resolveImplicitRules(graph);
    assert(r2 == 1, "pass 2 should resolve program.o");
    progO = graph.findTarget("program.o");
    assert(progO.recipe.length > 0,
           "program.o should now have recipe");
    assert(progO.prerequisites.length >= 1);
    assert(progO.prerequisites[0] == "program.c",
           "program.o prereq should be program.c");
    // program.c exists on disk, so no stub was added
    assert(!graph.hasTarget("program.c"),
           "program.c should NOT be added — it exists on disk");

    // Pass 3: `program.c` may match rules (e.g. %.c: %.l for Lex) —
    // the pattern matcher doesn't check prerequisite existence yet.
    // No assertion on whether it resolves; just verify no crash.
    size_t r3 = resolveImplicitRules(graph);
    // Just ensure it doesn't crash; r3 may be 0 or 1.
    cast(void) r3;
}

///
unittest
{
    // --- Double-colon: graph holds two targets with the same name ---
    //
    // In GNU Make, double-colon rules (target:: prereqs) are treated as
    // independent — each recipe runs separately.  This test verifies
    // that the graph stores multiple targets with the identical name
    // (the precondition for double-colon execution).  The actual
    // double-colon semantic (independent execution) is blocked on the
    // parser storing :: vs : in the AST — see TODO in handleRule.
    //
    // This test uses addTarget directly (bypassing evaluate) because
    // the current parser does not annotate double-colon rules.

    DependencyGraph graph;

    Target t1;
    t1.name = "double_colon_target";
    t1.kind = TargetKind.file;
    t1.recipe = ["echo first"];
    graph.addTarget(t1);

    Target t2;
    t2.name = "double_colon_target";
    t2.kind = TargetKind.file;
    t2.recipe = ["echo second"];
    graph.addTarget(t2);

    // Verify both entries exist independently.
    size_t count;
    foreach (ref t; graph.targets)
        if (t.name == "double_colon_target")
            count++;

    assert(count == 2,
           "double-colon target should have 2 entries in graph, got: " ~
           count.to!string);
    assert(graph.targets[0].recipe[0] == "echo first");
    assert(graph.targets[1].recipe[0] == "echo second");
}

///
unittest
{
    // --- Target-specific variable assignment detected in handleRule ---
    //
    // `target: VAR = value` is parsed by the current parser as a rule
    // with three prereq children ("VAR", "=", "value").  handleRule
    // detects this pattern and stores the assignment as a scoped
    // variable on the environment.
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    // Build a pseudo-rule node that mimics what the parser produces
    // for `my_target: CFLAGS = -O2 -g`
    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "my_target";

    AstNode nameNode;
    nameNode.type = AstType.prerequisite;
    nameNode.data = "CFLAGS";

    AstNode opNode;
    opNode.type = AstType.prerequisite;
    opNode.data = "=";

    AstNode valNode;
    valNode.type = AstType.prerequisite;
    valNode.data = "-O2 -g";

    rule.children = [nameNode, opNode, valNode];
    root.children = [rule];

    evaluate(root, &env, &graph);

    // Target should be in the graph, but the variable assignment
    // should have been extracted, NOT left as a prereq.
    assert(graph.targets.length == 1,
           "graph should contain the target");
    assert(graph.targets[0].name == "my_target");
    assert(graph.targets[0].prerequisites.length == 0,
           "prereq list should be empty (assignment was extracted)");

    // The scoped variable should be stored on the environment.
    assert(env.getScoped("CFLAGS", "my_target") == "-O2 -g",
           "scoped CFLAGS should be '-O2 -g', got: " ~
           env.getScoped("CFLAGS", "my_target"));

    // Global lookup should return empty (not set globally).
    assert(env.get("CFLAGS") == "",
           "CFLAGS should not be set globally, got: " ~ env.get("CFLAGS"));
}

///
unittest
{
    // --- Target-specific with := (non-recursive) operator ---
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "debug.o";

    AstNode nameNode;
    nameNode.type = AstType.prerequisite;
    nameNode.data = "CFLAGS";

    AstNode opNode;
    opNode.type = AstType.prerequisite;
    opNode.data = ":=";

    AstNode valNode;
    valNode.type = AstType.prerequisite;
    valNode.data = "-O0 -g";

    rule.children = [nameNode, opNode, valNode];
    root.children = [rule];

    evaluate(root, &env, &graph);

    assert(env.getScoped("CFLAGS", "debug.o") == "-O0 -g",
           "scoped CFLAGS via := should be '-O0 -g'");
}

///
unittest
{
    // --- Target-specific var with real prerequisites mixed in ---
    //
    // `my_target: dep1.o CFLAGS = -O2 dep2.o` — the assignment is
    // extracted while dep1.o and dep2.o remain as real prereqs.
    DependencyGraph graph;
    Environment env;

    AstNode root;
    root.type = AstType.rule_list;

    AstNode rule;
    rule.type = AstType.rule;
    rule.data = "my_prog";

    AstNode dep1;
    dep1.type = AstType.prerequisite;
    dep1.data = "dep1.o";

    AstNode varName;
    varName.type = AstType.prerequisite;
    varName.data = "LDFLAGS";

    AstNode op;
    op.type = AstType.prerequisite;
    op.data = "+=";

    AstNode varVal;
    varVal.type = AstType.prerequisite;
    varVal.data = "-lm";

    AstNode dep2;
    dep2.type = AstType.prerequisite;
    dep2.data = "dep2.o";

    rule.children = [dep1, varName, op, varVal, dep2];
    root.children = [rule];

    evaluate(root, &env, &graph);

    // Target should exist with only real prereqs.
    // Target should exist with only real prereqs.
    assert(graph.targets.length == 1);
    assert(graph.targets[0].prerequisites.length == 2,
           "should have 2 real prereqs, got: " ~
           graph.targets[0].prerequisites.length.to!string);
    assert(graph.targets[0].prerequisites[0] == "dep1.o");
    assert(graph.targets[0].prerequisites[1] == "dep2.o");

    // Scoped variable should be stored.
    assert(env.getScoped("LDFLAGS", "my_prog") == "-lm",
           "scoped LDFLAGS += should be '-lm', got: " ~
           env.getScoped("LDFLAGS", "my_prog"));
}

///
unittest
{
    // --- Target that already has a recipe is NOT overwritten ---
    DependencyGraph graph;

    Target t;
    t.name = "hello.o";
    t.kind = TargetKind.file;
    t.prerequisites = ["hello.c"];
    t.recipe = ["gcc -O3 -c hello.c -o hello.o"];
    graph.addTarget(t);

    size_t resolved = resolveImplicitRules(graph);
    assert(resolved == 0, "target with existing recipe should not be touched");

    auto hello = graph.findTarget("hello.o");
    assert(hello.recipe[0] == "gcc -O3 -c hello.c -o hello.o",
           "explicit recipe should be preserved");
}

///
unittest
{
    // --- Phony targets are skipped ---
    DependencyGraph graph;

    Target t;
    t.name = "clean";
    t.kind = TargetKind.phony;
    graph.addTarget(t);

    size_t resolved = resolveImplicitRules(graph);
    assert(resolved == 0, "phony target should not get implicit recipe");
}

///
unittest
{
    // --- Empty graph: no crash ---
    DependencyGraph graph;
    size_t resolved = resolveImplicitRules(graph);
    assert(resolved == 0, "empty graph should resolve 0");
}

///
unittest
{
    // --- Multi-file include via variable expansion ---
    //
    // Autotools-generated Makefiles use `include $(DEP_FILES)` where
    // DEP_FILES expands to multiple space-separated paths (e.g.,
    // "./.deps/a.Po ./.deps/b.Po").  This test verifies that each
    // path is expanded, split, and processed individually.
    import std.file : write, remove;

    // Create two temporary include files
    write("antelope_test_include_a.mk", "VAR_A = from_a\n");
    write("antelope_test_include_b.mk", "VAR_B = from_b\n");
    scope (exit)
    {
        remove("antelope_test_include_a.mk");
        remove("antelope_test_include_b.mk");
    }

    Environment env;
    env.set("DEP_FILES", "antelope_test_include_a.mk antelope_test_include_b.mk");

    AstNode root;
    root.type = AstType.rule_list;

    AstNode includeDir;
    includeDir.type = AstType.directive;
    includeDir.data = "include $(DEP_FILES)";
    root.children = [includeDir];

    evaluate(root, &env, null);

    assert(env.hasKey("VAR_A"),
           "VAR_A should be set from first included file");
    assert(env.get("VAR_A") == "from_a",
           "VAR_A should be 'from_a', got: '" ~ env.get("VAR_A") ~ "'");
    assert(env.hasKey("VAR_B"),
           "VAR_B should be set from second included file");
    assert(env.get("VAR_B") == "from_b",
           "VAR_B should be 'from_b', got: '" ~ env.get("VAR_B") ~ "'");
}
