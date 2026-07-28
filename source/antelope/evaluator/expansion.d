/// Variable expansion and substitution at evaluation time.
///
/// This module implements GNU Make-compatible recursive variable expansion.
/// It is the core string-processing engine responsible for resolving
/// `$(VAR)`, `$$`, automatic variables ($@, $<, etc.), D/F suffix extraction,
/// and `$(call ...)` substitution — all with circular-reference detection.
module antelope.evaluator.expansion;

import antelope.shell.environment;
import antelope.diagnostics.errors;
import antelope.parser.functions;
import std.string : lastIndexOf, strip, indexOf;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Expand all variable references in a string.
///
/// The expansion is recursive: when a variable's value itself contains
/// variable references, those are expanded in turn.  Undefined variables
/// expand to the empty string (standard GNU Make behaviour).  Circular
/// references (A → B → A) are detected and reported rather than looping.
///
/// Supported syntax:
///   * `$$`        → literal `$`
///   * `$@`        → current target name
///   * `$<`        → first prerequisite
///   * `$^`        → all prerequisites (unique, space-separated)
///   * `$+`        → all prerequisites (duplicates preserved)
///   * `$?`        → prerequisites newer than target (all prereqs for now)
///   * `$*`        → pattern stem
///   * `$%`        → archive member (not yet implemented → "")
///   * `$|`        → order-only prerequisites (not yet implemented → "")
///   * `$(VAR)`    → environment variable lookup + recursive expansion
///   * `${VAR}`    → same as `$(VAR)`
///   * `$(@D)` / `$(@F)`   → directory / file part of target
///   * `$(<D)` / `$(<F)`   → directory / file part of first prerequisite
///   * `$(^D)` / `$(^F)`   → directory / file parts of all prerequisites
///   * `$(*D)` / `$(*F)`   → directory / file part of stem
///   * `$(call FUNC,arg1,arg2,…)` → call-style expansion
///
/// Params:
///   input          = String to expand.
///   env            = Pointer to the variable environment (may be null).
///   currentTarget  = Value for `$@` (current target name).
///   currentPrereqs = Values for `$<`, `$^`, `$+`, `$?`.
///   stem           = Value for `$*` (pattern stem).
///
/// Returns: The fully-expanded string.
string expand(string input, Environment* env, string currentTarget = "",
              string[] currentPrereqs = [], string stem = "")
{
    string[] chain;
    return expandImpl(input, env, currentTarget, currentPrereqs, stem, chain);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Directory part of a path (up to and including the last `/`, or `./`).
private string dirPart(string path)
{
    auto idx = lastIndexOf(path, "/");
    if (idx == size_t.max)             // D's lastIndexOf returns size_t.max on no-match
        return "./";
    return path[0 .. idx + 1];
}

/// File part of a path (everything after the last `/`).
private string filePart(string path)
{
    auto idx = lastIndexOf(path, "/");
    if (idx == size_t.max)
        return path;
    return path[idx + 1 .. $];
}

/// Apply `dirPart` or `filePart` to each string in `values` and join with space.
private string applyDirFile(string[] values, bool wantDir)
{
    if (values.length == 0)
        return "";
    import std.array : appender;
    auto buf = appender!string();
    bool first = true;
    foreach (v; values)
    {
        if (!first) buf.put(" ");
        first = false;
        buf.put(wantDir ? dirPart(v) : filePart(v));
    }
    return buf.data;
}

/// Resolve a single-character automatic variable.
/// Never returns null — always returns a string.
private string resolveAutoVar(char c, string currentTarget, string[] currentPrereqs,
                              string stem)
{
    final switch (c)
    {
        case '@': return currentTarget;
        case '<': return currentPrereqs.length > 0 ? currentPrereqs[0] : "";
        case '^':
        {
            // Unique prerequisites (order preserved, first occurrence kept).
            if (currentPrereqs.length == 0)
                return "";
            import std.array : appender;
            auto buf = appender!string();
            bool[string] seen;
            bool first = true;
            foreach (p; currentPrereqs)
            {
                if (p in seen) continue;
                seen[p] = true;
                if (!first) buf.put(" ");
                first = false;
                buf.put(p);
            }
            return buf.data;
        }
        case '+':  // All prereqs, duplicates preserved, space-separated.
        {
            if (currentPrereqs.length == 0)
                return "";
            import std.array : appender;
            auto buf = appender!string();
            foreach (i, p; currentPrereqs)
            {
                if (i > 0) buf.put(" ");
                buf.put(p);
            }
            return buf.data;
        }
        case '?':
        {
            // "Prereqs newer than target" — compare timestamps and
            // return only those prerequisites that are newer than the
            // target file.  This matches GNU Make's $? semantics.
            if (currentPrereqs.length == 0) return "";
            import antelope.filesystem.timestamps;
            import std.array : appender;
            auto buf = appender!string();
            bool first = true;
            long targetTime = getTimestamp(currentTarget);
            foreach (p; currentPrereqs)
            {
                long pt = getTimestamp(p);
                if (pt > targetTime || targetTime == -1)
                {
                    if (!first) buf.put(" ");
                    first = false;
                    buf.put(p);
                }
            }
            return buf.data;
        }
        case '*': return stem;
        case '%': return "";  // Archive member — not yet implemented.
        case '|': return "";  // Order-only prereqs — not yet implemented.
    }
}

/// Resolve content found between `(` / `)` or `{` / `}`.
///
/// The content may be:
///   * `call FUNC,arg1,arg2,…`  → call-style expansion
///   * `@D`, `<F`, `^D`, `*F`, etc. → automatic var D/F suffix
///   * `VAR` or `VAR_$(NESTED)`   → regular variable lookup
///
/// `closer` is `)` or `}` (unused except for potential error messages).
private string resolveParenContent(string content, char closer, Environment* env,
                                   string currentTarget, string[] currentPrereqs,
                                   string stem, ref string[] chain)
{
    // --- $(call FUNC,arg1,arg2,…) ------------------------------------------
    if (content.length >= 5 && content[0 .. 5] == "call ")
    {
        return expandCall(content[5 .. $], env, currentTarget, currentPrereqs, stem, chain);
    }

    // --- Built-in function calls: $(shell ...), $(subst ...), etc. -----------
    // Detect if the first word is a known GNU Make function name.
    import std.string : indexOf;
    auto firstSpace = indexOf(content, ' ');
    string firstWord = firstSpace >= 0 ? content[0 .. firstSpace] : content;
    if (isBuiltinFunction(firstWord))
    {
        return evaluateBuiltinCall(firstWord, content, env, currentTarget, currentPrereqs, stem);
    }

    // --- Automatic var with D/F suffix  ($(@D), $(<F), $(^D), etc.) ---------
    if (content.length == 2 &&
        (content[0] == '@' || content[0] == '<' || content[0] == '^' ||
         content[0] == '+' || content[0] == '?' || content[0] == '*') &&
        (content[1] == 'D' || content[1] == 'F'))
    {
        bool wantDir = (content[1] == 'D');
        char av = content[0];

        // For multi-value automatic vars ($^D, $+D, $?D) we apply
        // dirPart / filePart to each element.
        if (av == '^' || av == '+' || av == '?')
        {
            string joined = resolveAutoVar(av, currentTarget, currentPrereqs, stem);
            if (joined.length == 0) return "";
            import std.array : split;
            auto parts = split(joined, " ");
            return applyDirFile(parts, wantDir);
        }

        // Single-value automatic vars ($@, $<, $*)
        string single = resolveAutoVar(av, currentTarget, currentPrereqs, stem);
        if (single.length == 0) return "";
        return wantDir ? dirPart(single) : filePart(single);
    }

    // --- Substitution reference: $(VAR:old=new) → $(patsubst old,new,$(VAR)) ---
    auto colonIdx = indexOf(content, ':');
    if (colonIdx >= 0 && colonIdx < content.length - 1 &&
        content[colonIdx + 1] != '=' && indexOf(content[colonIdx + 1 .. $], '=') >= 0)
    {
        // Syntax: VAR:old=new
        // Per GNU Make: $(var:a=b) ≡ $(patsubst %a,%b,$(var))
        // The '%' is prepended so that patsubst matches at end-of-word.
        string varName = content[0 .. colonIdx];
        auto eqIdx = indexOf(content[colonIdx + 1 .. $], '=');
        string oldPat = "%" ~ content[colonIdx + 1 .. colonIdx + 1 + eqIdx];
        string newPat = "%" ~ content[colonIdx + 1 + eqIdx + 1 .. $];
        // Equivalent to $(patsubst %oldPat,%newPat,$(varName))
        string varValue = env ? env.get(varName) : "";
        if (varValue.length > 0)
        {
            import antelope.evaluator.functions;
            import antelope.parser.functions;
            return evaluateFunction(BuiltinFunction.patsubst, [oldPat, newPat, varValue], env);
        }
        return "";
    }

    // --- Regular variable lookup -------------------------------------------
    // First, recursively expand any nested `$` references in the content.
    // This handles $(VAR_$(NESTED)) — expand $(NESTED) first, then look up.
    string expandedName = expandImpl(content, env, currentTarget, currentPrereqs, stem, chain);

    if (expandedName.length == 0)
        return "";

    // Environment lookup — consult target-scoped variables first.
    string value = env ? env.getScoped(expandedName, currentTarget) : "";
    if (value.length == 0)
        return "";

    // Circular-reference guard.
    foreach (c; chain)
    {
        if (c == expandedName)
        {
            // Found a cycle — report and bail out.
            // (In the future this could use a diagnostic emitter.)
            return "";
        }
    }

    chain ~= expandedName;
    scope (exit) chain = chain[0 .. $ - 1];
    return expandImpl(value, env, currentTarget, currentPrereqs, stem, chain);
}

/// Expand a `$(call FUNC,arg1,arg2,…)` reference.
///
/// `rest` is everything after `"call "` — i.e. `"FUNC,arg1,arg2,…"`.
/// Steps:
///   1. Split on top-level commas to get variable name + args.
///   2. Expand the variable name to find which variable to invoke.
///   3. Look up its value from the environment.
///   4. Substitute `$1`, `$2`, … in the value with the expanded args.
///   5. Recursively expand the result.
private string expandCall(string rest, Environment* env,
                          string currentTarget, string[] currentPrereqs,
                          string stem, ref string[] chain)
{
    // Split `FUNC,arg1,arg2,…` on top-level commas.
    string[] parts;
    {
        import std.array : appender;
        auto buf = appender!(string[])();
        size_t pos = 0;
        size_t depth = 0;
        size_t start = 0;
        while (pos < rest.length)
        {
            char ch = rest[pos];
            if (ch == '(' || ch == '{') depth++;
            else if (ch == ')' || ch == '}') depth--;
            else if (ch == ',' && depth == 0)
            {
                buf.put(rest[start .. pos]);
                start = pos + 1;
            }
            pos++;
        }
        // Last segment.
        buf.put(rest[start .. $]);
        parts = buf.data;
    }

    if (parts.length == 0)
        return "";

    // Parts[0] is the function name — expand it to get the variable name.
    string funcName = expandImpl(parts[0], env, currentTarget, currentPrereqs, stem, chain);

    if (funcName.length == 0)
        return "";

    // Look up the function body.
    string body = env ? env.get(funcName) : "";
    if (body.length == 0)
        return "";

    // Expand each argument.
    string[] expandedArgs;
    foreach (i; 1 .. parts.length)
    {
        expandedArgs ~= expandImpl(parts[i], env, currentTarget, currentPrereqs, stem, chain);
    }

    // Substitute $1, $2, … in the body.
    // We scan the body character by character for $N patterns.
    string bodyWithSubs = substituteCallArgs(body, expandedArgs);

    // Recursively expand the result (it may contain further variable refs).
    return expandImpl(bodyWithSubs, env, currentTarget, currentPrereqs, stem, chain);
}

/// Substitute `$1`, `$2`, …, `$0` (the function name) in `body` with the
/// corresponding values from `args`.
///
/// `args[0]` corresponds to `$1`, `args[1]` to `$2`, etc.
/// `$0` is set to the function name (already resolved).
///
/// `$$` in the body is left as a literal `$` (it was already quoted).
/// Unknown `$N` is replaced by the empty string.
private string substituteCallArgs(string body, string[] args)
{
    import std.array : appender;
    auto buf = appender!string();
    size_t i = 0;
    while (i < body.length)
    {
        if (body[i] == '$')
        {
            i++;
            if (i >= body.length)
            {
                buf.put('$');
                break;
            }
            char c = body[i];
            if (c == '$')
            {
                buf.put('$');
                i++;
                continue;
            }
            // Is it a digit?  $0, $1, …, $9
            if (c >= '0' && c <= '9')
            {
                uint n = c - '0';
                if (n == 0)
                {
                    // $0 is replaced by empty string (or function name — but
                    // GNU Make doesn't use $0 in call; it's the function name
                    // and is not substituted). Leave as empty for now.
                    buf.put("");
                }
                else if (n <= args.length)
                {
                    buf.put(args[n - 1]);
                }
                else
                {
                    // Unknown $N → ""
                }
                i++;
                continue;
            }
            // Not a digit — output $ and the char (e.g. $( inside body).
            buf.put('$');
            buf.put(c);
            i++;
        }
        else
        {
            buf.put(body[i]);
            i++;
        }
    }
    return buf.data;
}

/// Core expansion implementation — recursive, with chain tracking for
/// circular-reference detection.
private string expandImpl(string input, Environment* env, string currentTarget,
                          string[] currentPrereqs, string stem, ref string[] chain)
{
    import std.array : appender;
    auto buf = appender!string();
    size_t i = 0;

    while (i < input.length)
    {
        if (input[i] == '$')
        {
            i++;
            if (i >= input.length)
            {
                buf.put('$');
                break;
            }

            char c = input[i];

            // $$ → literal $
            if (c == '$')
            {
                buf.put('$');
                i++;
                continue;
            }

            // Single-character $X variable references.
            // $@, $<, $^, etc. → automatic variables
            if (c == '@' || c == '<' || c == '^' || c == '+' ||
                c == '?' || c == '*' || c == '%' || c == '|')
            {
                buf.put(resolveAutoVar(c, currentTarget, currentPrereqs, stem));
                i++;
                continue;
            }
            // $1..$9, $0 → positional parameters (call, foreach, etc.)
            // and any other single-char variable reference
            if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_')
            {
                string varName = [c];
                string val = env ? env.get(varName) : "";
                buf.put(val);
                i++;
                continue;
            }

            // $(…) or ${…}
            if (c == '(' || c == '{')
            {
                char openChar = c;
                char closeChar = (c == '(') ? ')' : '}';
                i++;  // skip opening delimiter

                size_t contentStart = i;
                int depth = 1;
                while (i < input.length && depth > 0)
                {
                    if (input[i] == openChar)
                        depth++;
                    else if (input[i] == closeChar)
                        depth--;
                    if (depth > 0)
                        i++;
                }

                if (i >= input.length)
                {
                    // Unterminated $('… or ${… — output literally.
                    buf.put('$');
                    buf.put(openChar);
                    buf.put(input[contentStart .. $]);
                    break;
                }

                string content = input[contentStart .. i];
                i++;  // skip closing delimiter

                buf.put(resolveParenContent(content, closeChar, env, currentTarget,
                                            currentPrereqs, stem, chain));
                continue;
            }

            // Unknown $X — output literally.
            buf.put('$');
            buf.put(c);
            i++;
        }
        else
        {
            buf.put(input[i]);
            i++;
        }
    }

    return buf.data;
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

///
unittest
{
    // --- Simple $(VAR) expansion ---
    {
        Environment env;
        env.set("FOO", "bar");
        string result = expand("$(FOO)", &env);
        assert(result == "bar", "Simple $(FOO) should expand to 'bar', got: " ~ result);
    }

    // --- ${VAR} syntax ---
    {
        Environment env;
        env.set("FOO", "baz");
        string result = expand("${FOO}", &env);
        assert(result == "baz", "${FOO} should expand to 'baz', got: " ~ result);
    }

    // --- $$ → literal $ ---
    {
        Environment env;
        string result = expand("prefix $$ suffix", &env);
        assert(result == "prefix $ suffix", "$$ should become '$', got: " ~ result);

        result = expand("$$$$", &env);
        assert(result == "$$", "$$$$ should become '$$', got: " ~ result);
    }

    // --- $@ → current target ---
    {
        Environment env;
        string result = expand("$@", &env, "myfile.o");
        assert(result == "myfile.o", "$@ should be target name, got: " ~ result);
    }

    // --- $< → first prerequisite ---
    {
        Environment env;
        string result = expand("$<", &env, "", ["a.c", "b.c"]);
        assert(result == "a.c", "$< should be first prereq, got: " ~ result);

        result = expand("$<", &env, "", []);
        assert(result == "", "$< with no prereqs should be empty, got: " ~ result);
    }

    // --- $^ → all prereqs, unique ---
    {
        Environment env;
        string result = expand("$^", &env, "", ["a.c", "b.c", "a.c"]);
        assert(result == "a.c b.c", "$^ should dedupe prereqs, got: " ~ result);
    }

    // --- $+ → all prereqs, duplicates preserved ---
    {
        Environment env;
        string result = expand("$+", &env, "", ["a.c", "b.c", "a.c"]);
        assert(result == "a.c b.c a.c", "$+ should preserve duplicates, got: " ~ result);
    }

    // --- $* → stem ---
    {
        Environment env;
        string result = expand("$*", &env, "", [], "foo");
        assert(result == "foo", "$* should be stem, got: " ~ result);
    }

    // --- $% → "" (not implemented) ---
    {
        Environment env;
        string result = expand("$%", &env);
        assert(result == "", "$% should be empty (not implemented), got: " ~ result);
    }

    // --- $| → "" (not implemented) ---
    {
        Environment env;
        string result = expand("$|", &env);
        assert(result == "", "$| should be empty (not implemented), got: " ~ result);
    }

    // --- $(@D) → directory part of target ---
    {
        Environment env;
        string result = expand("$(@D)", &env, "src/sub/file.o");
        assert(result == "src/sub/", "$(@D) should be dir part, got: " ~ result);

        result = expand("$(@D)", &env, "file.o");
        assert(result == "./", "$(@D) with no slash should be './', got: " ~ result);
    }

    // --- $(@F) → file part of target ---
    {
        Environment env;
        string         result = expand("$(@F)", &env, "src/sub/file.o");
        assert(result == "file.o", "$(@F) should be file part, got: " ~ result);

        result = expand("$(@F)", &env, "file.o");
        assert(result == "file.o", "$(@F) with no slash should be full name, got: " ~ result);
    }

    // --- $(<D) and $(<F) ---
    {
        Environment env;
        string result = expand("$(<D)", &env, "", ["src/a.c"]);
        assert(result == "src/", "$(<D) should be dir part of first prereq, got: " ~ result);

        result = expand("$(<F)", &env, "", ["src/a.c"]);
        assert(result == "a.c", "$(<F) should be file part of first prereq, got: " ~ result);
    }

    // --- $(^D) and $(^F) ---
    {
        Environment env;
        string result = expand("$(^D)", &env, "", ["src/a.c", "inc/b.h"]);
        assert(result == "src/ inc/", "$(^D) with multi prereqs, got: " ~ result);

        result = expand("$(^F)", &env, "", ["src/a.c", "inc/b.h"]);
        assert(result == "a.c b.h", "$(^F) with multi prereqs, got: " ~ result);
    }

    // --- Nested expansion: $(VAR_$(NESTED)) ---
    {
        Environment env;
        env.set("SUFFIX", "FLAGS");
        env.set("CXXFLAGS", "-O2 -Wall");
        string result = expand("$(CXX$(SUFFIX))", &env);
        assert(result == "-O2 -Wall", "Nested expansion failed, got: " ~ result);
    }

    // --- Undefined variable → "" ---
    {
        Environment env;
        string result = expand("$(UNDEFINED_VAR)", &env);
        assert(result == "", "Undefined var should be empty, got: " ~ result);
    }

    // --- $(call ...) basic ---
    {
        Environment env;
        env.set("reverse", "$2 $1");
        string result = expand("$(call reverse,a,b)", &env);
        assert(result == "b a", "call reverse failed, got: " ~ result);
    }

    // --- $(call ...) with extra args (unused $N → "") ---
    {
        Environment env;
        env.set("prefix", "[$1]");
        string result = expand("$(call prefix,hello)", &env);
        assert(result == "[hello]", "call prefix failed, got: " ~ result);
    }

    // --- $(call ...) with nested $ in args ---
    {
        Environment env;
        env.set("VAL", "xyz");
        env.set("wrap", "<$1>");
        string result = expand("$(call wrap,$(VAL))", &env);
        assert(result == "<xyz>", "call with nested var in arg failed, got: " ~ result);
    }

    // --- Circular reference detection ---
    {
        Environment env;
        env.set("A", "$(B)");
        env.set("B", "$(A)");
        string result = expand("$(A)", &env);
        assert(result == "", "Circular A→B→A should return empty, got: " ~ result);
    }

    // --- Circular self-reference ---
    {
        Environment env;
        env.set("X", "$(X)");
        string result = expand("$(X)", &env);
        assert(result == "", "Self-circular X→X should return empty, got: " ~ result);
    }

    // --- Deeply nested expansion ---
    {
        Environment env;
        env.set("A", "1$(B)");
        env.set("B", "2$(C)");
        env.set("C", "3");
        string result = expand("$(A)", &env);
        assert(result == "123", "Deeply nested A→B→C failed, got: " ~ result);
    }

    // --- Multiple $ in same string ---
    {
        Environment env;
        env.set("NAME", "Antelope");
        env.set("VER", "1.0");
        string result = expand("$(NAME) v$(VER) $$HOME", &env);
        assert(result == "Antelope v1.0 $HOME",
               "Multiple $ expansion failed, got: " ~ result);
    }

    // --- Literal string passthrough (no $) ---
    {
        Environment env;
        string result = expand("hello world", &env);
        assert(result == "hello world", "Plain string should pass through, got: " ~ result);
    }

    // --- $? (newer prereqs) — all prereqs returned when target doesn't exist ---
    {
        Environment env;
        // Both target ("") and prereqs ("a.c", "b.c") are non-existent files,
        // so getTimestamp returns -1 for all.  Since targetTime == -1,
        // all prereqs are considered newer.
        string result = expand("$?", &env, "", ["a.c", "b.c", "a.c"]);
        assert(result == "a.c b.c a.c", "$? should return all when target absent, got: " ~ result);
    }

    // --- Null env pointer — all vars → "" ---
    {
        string result = expand("$(ANYTHING)", null);
        assert(result == "", "Null env should treat all vars as undefined, got: " ~ result);
    }

    // --- call with $0 → empty ---
    {
        Environment env;
        env.set("showall", "$0 $1 $2");
        string result = expand("$(call showall,foo,bar)", &env);
        // $0 is empty, $1=foo, $2=bar
        assert(result == " foo bar", "call with $0, got: " ~ result);
    }

    // --- call with nested function name expansion ---
    {
        Environment env;
        env.set("WHICH", "upper");
        env.set("upper", "[$1]");
        string result = expand("$(call $(WHICH),text)", &env);
        assert(result == "[text]", "call with nested func name, got: " ~ result);
    }

    // --- Unclosed $( → output literally ---
    {
        Environment env;
        env.set("FOO", "bar");
        string result = expand("start $(FOO", &env);
        assert(result == "start $(FOO", "Unclosed $( should be literal, got: " ~ result);
    }
}

/// Check if a word is a known GNU Make built-in function name.
bool isBuiltinFunction(string word)
{
    switch (word)
    {
        case "subst": case "patsubst": case "strip": case "findstring":
        case "filter": case "filter-out": case "sort": case "word":
        case "words": case "wordlist": case "firstword": case "lastword":
        case "dir": case "notdir": case "suffix": case "basename":
        case "addsuffix": case "addprefix": case "join":
        case "wildcard": case "realpath": case "abspath":
        case "shell": case "error": case "warning": case "info":
        case "foreach": case "call": case "value": case "origin": case "flavor":
            return true;
        default:
            return false;
    }
}

/// Evaluate a built-in function call from expansion context.
private string evaluateBuiltinCall(string funcName, string content, Environment* env,
    string currentTarget = "", string[] currentPrereqs = [], string stem = "")
{
    import antelope.evaluator.functions;
    import antelope.parser.functions;

    // Parse arguments with nesting-aware comma splitting.
    // Commas inside nested $(...) or ${...} are NOT argument separators.
    string[] args;
    size_t start = funcName.length;
    if (start < content.length && content[start] == ' ')
        start++;

    string rest = content[start .. $];
    size_t segStart = 0;
    int depth = 0;  // paren/brace nesting depth
    for (size_t i = 0; i < rest.length; i++)
    {
        char c = rest[i];
        if (c == '(' || c == '{') depth++;
        else if (c == ')' || c == '}') { if (depth > 0) depth--; }
        else if (c == ',' && depth == 0)
        {
            args ~= rest[segStart .. i].strip;
            segStart = i + 1;
        }
    }
    // Last segment
    if (segStart < rest.length)
        args ~= rest[segStart .. $].strip;

    // Recursively expand each argument before dispatching to the function.
    // Pass currentTarget/prereqs/stem so $@, $<, $^ work inside function args.
    // Functions that manage their own expansion (foreach, if, or, and)
    // receive raw (unexpanded) arguments.
    import antelope.parser.functions;
    BuiltinFunction bf = builtinFromName(funcName);
    bool preExpand = !isSelfExpanding(bf);
    string[] expandedArgs;
    foreach (arg; args)
    {
        if (preExpand)
            expandedArgs ~= expand(arg, env, currentTarget, currentPrereqs, stem);
        else
            expandedArgs ~= arg;
    }

    return evaluateFunction(bf, expandedArgs, env);
}

/// Returns true for functions that manage their own argument expansion
/// (matching GNU Make's `expand_args=0` flag).
private bool isSelfExpanding(BuiltinFunction bf)
{
    import antelope.parser.functions;
    switch (bf)
    {
        case BuiltinFunction.foreach_:
            return true;
        default:
            return false;
    }
}

/// Map function name string to BuiltinFunction enum.
BuiltinFunction builtinFromName(string name)
{
    import antelope.parser.functions;
    switch (name)
    {
        case "subst":      return BuiltinFunction.subst;
        case "patsubst":   return BuiltinFunction.patsubst;
        case "strip":      return BuiltinFunction.strip;
        case "findstring": return BuiltinFunction.findstring;
        case "filter":     return BuiltinFunction.filter;
        case "filter-out": return BuiltinFunction.filter_out;
        case "sort":       return BuiltinFunction.sort;
        case "word":       return BuiltinFunction.word;
        case "words":      return BuiltinFunction.words;
        case "wordlist":   return BuiltinFunction.wordlist;
        case "firstword":  return BuiltinFunction.firstword;
        case "lastword":   return BuiltinFunction.lastword;
        case "dir":        return BuiltinFunction.dir;
        case "notdir":     return BuiltinFunction.notdir;
        case "suffix":     return BuiltinFunction.suffix;
        case "basename":   return BuiltinFunction.basename;
        case "addsuffix":  return BuiltinFunction.addsuffix;
        case "addprefix":  return BuiltinFunction.addprefix;
        case "join":       return BuiltinFunction.join;
        case "wildcard":   return BuiltinFunction.wildcard;
        case "realpath":   return BuiltinFunction.realpath;
        case "abspath":    return BuiltinFunction.abspath;
        case "shell":      return BuiltinFunction.shell;
        case "error":      return BuiltinFunction.error;
        case "warning":    return BuiltinFunction.warning;
        case "info":       return BuiltinFunction.info;
        case "foreach":    return BuiltinFunction.foreach_;
        case "call":       return BuiltinFunction.call;
        case "value":      return BuiltinFunction.value;
        case "origin":     return BuiltinFunction.origin;
        case "flavor":     return BuiltinFunction.flavor;
        default:           return BuiltinFunction.info;
    }
}
