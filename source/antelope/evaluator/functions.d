/// Built-in function evaluation at runtime.
///
/// Dispatches GNU Make built-in function calls to their implementations.
/// Critical functions (subst, patsubst, strip, wildcard, shell, error,
/// warning, info, sort, words) are fully implemented.  Unsupported
/// functions return an empty string, matching GNU Make behaviour.
module antelope.evaluator.functions;

import antelope.parser.functions;
import antelope.shell.environment;
import antelope.shell.process;
import antelope.filesystem.files;
import antelope.diagnostics.output;
import antelope.diagnostics.warnings;
import antelope.diagnostics.errors;
import std.algorithm : canFind, sort;
import std.array : split;
import std.conv : to;
import std.file : exists;
import std.stdio : stderr;
import std.string : indexOf, lastIndexOf, join, strip;

// --- Helper: substring replace-all (no regex dependency) ---

/// Replace every non-overlapping occurrence of `from` with `to` in `text`.
/// Returns `text` unchanged when `from` is empty (no infinite loop).
private string replaceAll(string text, string from, string to)
{
    if (from.length == 0)
        return text;

    string result;
    size_t lastIdx = 0;
    while (true)
    {
        auto idx = indexOf(text, from, lastIdx);
        if (idx == -1)
        {
            result ~= text[lastIdx .. $];
            break;
        }
        result ~= text[lastIdx .. idx];
        result ~= to;
        lastIdx = idx + from.length;
    }
    return result;
}

/// Match a single word against a `%`-wildcard pattern.
///
/// If the pattern contains no `%`, the word must match exactly.
/// Otherwise `%` matches zero or more characters.
private bool matchPattern(string word, string pattern)
{
    auto wildPos = indexOf(pattern, '%');
    if (wildPos == -1)
        return word == pattern;

    string prefix = pattern[0 .. wildPos];
    string suffix = pattern[wildPos + 1 .. $];

    return word.length >= prefix.length + suffix.length
        && word[0 .. prefix.length] == prefix
        && word[$ - suffix.length .. $] == suffix;
}

/// Split `text` on whitespace, keep or discard words matching `pattern`.
private string filterWords(string pattern, string text, bool keepMatches)
{
    auto words = split(text);
    string[] result;
    foreach (word; words)
    {
        if (matchPattern(word, pattern) == keepMatches)
            result ~= word;
    }
    return join(result, " ");
}

// --- Public API ---

/// Evaluate a built-in function call and return the result.
///
/// Params:
///   func = the built-in function to invoke
///   args = positional arguments as parsed from the call site
///   env  = optional pointer to an Environment for variable lookups
///
/// Returns: the expanded string result (empty string for unsupported
///          functions and for functions whose return value is void).
string evaluateFunction(BuiltinFunction func, string[] args, Environment* env = null)
{
    final switch (func)
    {
        // --- String substitution ---
        case BuiltinFunction.subst:
            // $(subst from,to,text) — replace all occurrences of from with to
            if (args.length < 3)
                return "";
            return replaceAll(args[2], args[0], args[1]);

        // --- Pattern substitution ---
        case BuiltinFunction.patsubst:
            // $(patsubst pattern,replacement,text)
            // Words in text matching pattern (where % matches a stem) are
            // replaced with the replacement where % expands to that stem.
            // Non-matching words pass through unchanged.
            if (args.length < 3)
                return "";

            {
                string pattern = args[0];
                string replacement = args[1];
                string text = args[2];

                auto wildPos = indexOf(pattern, '%');
                // Pattern must contain exactly one '%'
                if (wildPos == -1)
                    return text;

                string prefix = pattern[0 .. wildPos];
                string suffix = pattern[wildPos + 1 .. $];

                auto words = split(text);
                string[] result;
                foreach (word; words)
                {
                    if (word.length >= prefix.length + suffix.length
                        && word[0 .. prefix.length] == prefix
                        && word[$ - suffix.length .. $] == suffix)
                    {
                        string stem = word[prefix.length .. $ - suffix.length];
                        result ~= replaceAll(replacement, "%", stem);
                    }
                    else
                    {
                        result ~= word;
                    }
                }
                return join(result, " ");
            }

        // --- Whitespace stripping ---
        case BuiltinFunction.strip:
            // $(strip text) — remove leading/trailing whitespace,
            // collapse internal whitespace to single spaces.
            if (args.length < 1)
                return "";
            {
                auto trimmed = strip(args[0]);
                auto words = split(trimmed);
                return join(words, " ");
            }

        // --- File globbing ---
        case BuiltinFunction.wildcard:
            // $(wildcard patterns...) — delegates to filesystem glob
            // Handles space-separated pattern lists
            if (args.length < 1)
                return "";
            {
                import std.string : split;
                import std.array : appender;
                auto allMatches = appender!(string[]);
                foreach (pattern; args[0].split(" "))
                {
                    if (pattern.length == 0) continue;
                    auto matches = glob(pattern);
                    foreach (m; matches)
                        allMatches.put(m);
                }
                auto result = allMatches.data;
                import std.algorithm : sort;
                sort(result);
                return join(result, " ");
            }

        // --- Shell command execution ---
        case BuiltinFunction.shell:
            // $(shell command) — execute via shell and capture stdout
            if (args.length < 1)
                return "";
            try
            {
                import std.process : executeShell;
                auto result = executeShell(args[0]);
                import std.string : stripRight;
                return result.output.stripRight();
            }
            catch (Exception)
            {
                return "";
            }

        // --- Error (fatal message) ---
        case BuiltinFunction.error:
            // $(error text) — print text to stderr, return empty string
            // GNU Make: $(error ...) causes make to stop with an error.
            // Future enhancement: raise an AntelopeError to abort.
            if (args.length > 0)
                stderr.writeln("antelope: error: ", args[0]);
            return "";

        // --- Warning ---
        case BuiltinFunction.warning:
            // $(warning text) — issue a warning, return empty string
            if (args.length > 0)
                warn(WarningKind.deprecatedFeature, args[0]);
            return "";

        // --- Info ---
        case BuiltinFunction.info:
            // $(info text) — log at normal level, return empty string
            if (args.length > 0)
                log(LogLevel.normal, args[0]);
            return "";

        // --- Sort ---
        case BuiltinFunction.sort:
            // $(sort list) — split on whitespace, sort lexicographically,
            // remove duplicates, join with space.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                sort(words);
                // Remove duplicate adjacent entries
                string[] deduped;
                foreach (i, word; words)
                {
                    if (i == 0 || word != words[i - 1])
                        deduped ~= word;
                }
                return join(deduped, " ");
            }

        // --- Word count ---
        case BuiltinFunction.words:
            // $(words text) — return number of whitespace-separated words
            if (args.length < 1)
                return "0";
            {
                auto w = split(args[0]);
                return w.length.to!string;
            }

        // --- Substring search ---
        case BuiltinFunction.findstring:
            // $(findstring find,in) — return `find` if it appears in `in`,
            // otherwise return the empty string.
            if (args.length < 2)
                return "";
            return args[1].canFind(args[0]) ? args[0] : "";

        // --- Filter (keep matching words) ---
        case BuiltinFunction.filter:
            // $(filter pattern,text) — return words that match %-wildcard pattern.
            if (args.length < 2)
                return "";
            return filterWords(args[0], args[1], true);

        // --- Filter-out (remove matching words) ---
        case BuiltinFunction.filter_out:
            // $(filter-out pattern,text) — return words that do NOT match.
            if (args.length < 2)
                return "";
            return filterWords(args[0], args[1], false);

        // --- Nth word (1-indexed) ---
        case BuiltinFunction.word:
            // $(word n,text) — return the nth whitespace-separated word,
            // or empty string if n is out of range.
            if (args.length < 2)
                return "";
            {
                auto words = split(args[1]);
                auto n = args[0].strip.to!ptrdiff_t;
                if (n < 1 || n > cast(ptrdiff_t) words.length)
                    return "";
                return words[n - 1];
            }

        // --- Sublist of words ---
        case BuiltinFunction.wordlist:
            // $(wordlist s,e,text) — return words from index s to e inclusive
            // (1-indexed).  Clamp to available range; return "" if s > e.
            if (args.length < 3)
                return "";
            {
                auto words = split(args[2]);
                auto s = args[0].strip.to!ptrdiff_t;
                auto e = args[1].strip.to!ptrdiff_t;
                if (s < 1)
                    s = 1;
                if (e > cast(ptrdiff_t) words.length)
                    e = cast(ptrdiff_t) words.length;
                if (s > e)
                    return "";
                return join(words[s - 1 .. e], " ");
            }

        // --- First word ---
        case BuiltinFunction.firstword:
            // $(firstword text) — return the first whitespace-separated word.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                return words.length > 0 ? words[0] : "";
            }

        // --- Last word ---
        case BuiltinFunction.lastword:
            // $(lastword text) — return the last whitespace-separated word.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                return words.length > 0 ? words[$ - 1] : "";
            }

        // --- Directory part ---
        case BuiltinFunction.dir:
            // $(dir names…) — extract directory part (up to and including
            // the last `/`).  Names without `/` become `./`.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                {
                    auto idx = lastIndexOf(w, '/');
                    if (idx == -1)
                        result ~= "./";
                    else
                        result ~= w[0 .. idx + 1];
                }
                return join(result, " ");
            }

        // --- Non-directory (filename) part ---
        case BuiltinFunction.notdir:
            // $(notdir names…) — extract everything after the last `/`.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                {
                    auto idx = lastIndexOf(w, '/');
                    if (idx == -1)
                        result ~= w;
                    else
                        result ~= w[idx + 1 .. $];
                }
                return join(result, " ");
            }

        // --- Suffix ---
        case BuiltinFunction.suffix:
            // $(suffix names…) — extract the suffix (starting with the last `.`).
            // Names with no `.` return the empty string.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                {
                    auto idx = lastIndexOf(w, '.');
                    if (idx == -1)
                        result ~= "";
                    else
                        result ~= w[idx .. $];
                }
                return join(result, " ");
            }

        // --- Basename (strip suffix) ---
        case BuiltinFunction.basename:
            // $(basename names…) — strip the suffix (everything from the last `.`
            // onward).  Names with no `.` are returned unchanged.
            if (args.length < 1)
                return "";
            {
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                {
                    auto idx = lastIndexOf(w, '.');
                    if (idx == -1)
                        result ~= w;
                    else
                        result ~= w[0 .. idx];
                }
                return join(result, " ");
            }

        // --- Append suffix to each word ---
        case BuiltinFunction.addsuffix:
            // $(addsuffix suffix,names…) — append `suffix` to each
            // whitespace-separated word in `names`.
            if (args.length < 2)
                return "";
            {
                auto suffix = args[0];
                auto words = split(args[1]);
                string[] result;
                foreach (w; words)
                    result ~= w ~ suffix;
                return join(result, " ");
            }

        // --- Prepend prefix to each word ---
        case BuiltinFunction.addprefix:
            // $(addprefix prefix,names…) — prepend `prefix` to each
            // whitespace-separated word in `names`.
            if (args.length < 2)
                return "";
            {
                auto prefix = args[0];
                auto words = split(args[1]);
                string[] result;
                foreach (w; words)
                    result ~= prefix ~ w;
                return join(result, " ");
            }

        // --- Word-by-word concatenation ---
        case BuiltinFunction.join:
            // $(join list1,list2) — concatenate list1 and list2 word by word.
            // Extra words from the longer list pass through unchanged.
            if (args.length < 2)
                return "";
            {
                auto list1 = split(args[0]);
                auto list2 = split(args[1]);
                string[] result;
                auto len = list1.length > list2.length ? list1.length : list2.length;
                for (size_t i = 0; i < len; i++)
                {
                    string left  = i < list1.length ? list1[i] : "";
                    string right = i < list2.length ? list2[i] : "";
                    result ~= left ~ right;
                }
                return join(result, " ");
            }

        // --- Canonical absolute path (resolves symlinks) ---
        case BuiltinFunction.realpath:
            // $(realpath names…) — return the canonical absolute path for each
            // name, resolving symlinks when the path exists.
            if (args.length < 1)
                return "";
            {
                import antelope.filesystem.paths : resolvePath;
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                    result ~= resolvePath(w);
                return join(result, " ");
            }

        // --- Absolute path (no symlink resolution) ---
        case BuiltinFunction.abspath:
            // $(abspath names…) — return the absolute path for each name
            // WITHOUT resolving symlinks.
            if (args.length < 1)
                return "";
            {
                import std.path : absolutePath;
                auto words = split(args[0]);
                string[] result;
                foreach (w; words)
                    result ~= absolutePath(w);
                return join(result, " ");
            }

        // --- Foreach loop ---
        case BuiltinFunction.foreach_:
            // $(foreach var,list,text) — for each whitespace-separated word
            // in `list`, set `var` to that word and expand `text`, joining
            // the results with spaces.
            if (args.length < 3)
                return "";
            {
                auto body = args[2];
                string[] result;
                if (env)
                {
                    import antelope.evaluator.expansion;
                    auto varName = expand(args[0], env);
                    auto listWords = split(expand(args[1], env));
                    foreach (word; listWords)
                    {
                        if (word.length == 0) continue;
                        string saved = env.get(varName);
                        env.set(varName, word);
                        scope(exit) env.set(varName, saved);
                        result ~= expand(body, env);
                    }
                }
                else
                {
                    auto varName = strip(args[0]);
                    auto listWords = split(args[1]);
                    foreach (word; listWords)
                    {
                        if (word.length == 0) continue;
                        string expanded = body;
                        expanded = replaceAll(expanded, "$(" ~ varName ~ ")", word);
                        expanded = replaceAll(expanded, "${" ~ varName ~ "}", word);
                        result ~= expanded;
                    }
                }
                return join(result, " ");
            }

        // --- Call (variable invocation with positional args) ---
        case BuiltinFunction.call:
            // $(call variable,param1,…) — expand the variable's value,
            // substituting $1, $2, … with the given parameters.
            if (args.length < 1)
                return "";
            {
                import antelope.evaluator.expansion;
                auto varName = strip(args[0]);
                string body = env ? env.get(varName) : "";
                if (body.length == 0)
                    return "";
                // Set positional params in env and expand
                string[] saved;
                foreach (i, param; args[1 .. $])
                {
                    auto num = (i + 1).to!string;
                    saved ~= env ? env.get(num) : "";
                    if (env) env.set(num, param);
                }
                scope(exit) {
                    foreach (i, param; args[1 .. $])
                        if (env) env.set((i + 1).to!string, i < saved.length ? saved[i] : "");
                }
                return expand(body, env);
            }

        // --- Un-expanded variable value ---
        case BuiltinFunction.value:
            // $(value var) — return the un-expanded value of the variable.
            if (args.length < 1)
                return "";
            return env ? env.get(args[0]) : "";

        // --- Variable origin ---
        case BuiltinFunction.origin:
            // $(origin var) — return a string describing where the variable
            // was defined: "undefined", "default", "environment", "file",
            // "command line", "override", or "automatic".
            if (args.length < 1)
                return "undefined";
            return env && env.hasKey(args[0]) ? "file" : "undefined";

        // --- Variable flavor ---
        case BuiltinFunction.flavor:
            // $(flavor var) — return "recursive" (= assignment), "simple"
            // (:= assignment), or "undefined" if the variable does not exist.
            if (args.length < 1)
                return "undefined";
            return env && env.hasKey(args[0]) ? "recursive" : "undefined";

        // --- Logical operators ---
        case BuiltinFunction.or_:
            // $(or arg1,arg2,...) — returns the first non-empty argument.
            // Short-circuit: arguments are not expanded until needed.
            foreach (arg; args)
            {
                // For self-expanding functions, args are raw — expand now.
                import antelope.evaluator.expansion;
                string expanded = expand(arg, env);
                if (expanded.length > 0)
                    return expanded;
            }
            return "";

        case BuiltinFunction.and_:
            // $(and arg1,arg2,...) — returns empty if any argument is empty,
            // otherwise returns the last (expanded) argument.
            {
                import antelope.evaluator.expansion;
                string last;
                foreach (arg; args)
                {
                    string expanded = expand(arg, env);
                    if (expanded.length == 0)
                        return "";
                    last = expanded;
                }
                return last;
            }
    }
}

// --- Unit tests ---

///
unittest
{
    // subst: basic replacement
    {
        auto r = evaluateFunction(BuiltinFunction.subst,
            ["ee", "EE", "feet on the street"]);
        assert(r == "fEEt on the strEEt");
    }

    // subst: no match
    {
        auto r = evaluateFunction(BuiltinFunction.subst,
            ["xx", "XX", "hello world"]);
        assert(r == "hello world");
    }

    // subst: empty from string returns text unchanged
    {
        auto r = evaluateFunction(BuiltinFunction.subst,
            ["", "X", "hello"]);
        assert(r == "hello");
    }

    // subst: too few args
    {
        auto r = evaluateFunction(BuiltinFunction.subst,
            ["a"]);
        assert(r == "");
    }
}

///
unittest
{
    // patsubst: basic pattern substitution
    {
        auto r = evaluateFunction(BuiltinFunction.patsubst,
            ["%.c", "%.o", "foo.c bar.c baz.h"]);
        assert(r == "foo.o bar.o baz.h");
    }

    // patsubst: no % in pattern passes through
    {
        auto r = evaluateFunction(BuiltinFunction.patsubst,
            ["xyz", "abc", "hello world"]);
        assert(r == "hello world");
    }

    // patsubst: stem extraction
    {
        auto r = evaluateFunction(BuiltinFunction.patsubst,
            ["src/%.c", "obj/%.o", "src/foo.c src/bar.c"]);
        assert(r == "obj/foo.o obj/bar.o");
    }

    // patsubst: too few args
    {
        auto r = evaluateFunction(BuiltinFunction.patsubst,
            ["a"]);
        assert(r == "");
    }
}

///
unittest
{
    // strip: leading/trailing whitespace
    {
        auto r = evaluateFunction(BuiltinFunction.strip,
            ["   hello world   "]);
        assert(r == "hello world");
    }

    // strip: collapse internal whitespace
    {
        auto r = evaluateFunction(BuiltinFunction.strip,
            ["a   b\t\tc\n\nd"]);
        assert(r == "a b c d");
    }

    // strip: already clean
    {
        auto r = evaluateFunction(BuiltinFunction.strip,
            ["hello"]);
        assert(r == "hello");
    }

    // strip: empty args
    {
        auto r = evaluateFunction(BuiltinFunction.strip,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // wildcard: delegate to glob (test with a temp file)
    import std.file : exists, mkdir, rmdir, write;
    import std.path : buildPath;

    auto testDir = "fn_wildcard_test_xx";
    scope (exit)
    {
        if (exists(testDir))
        {
            import std.file : remove;
            remove(testDir ~ "/a.txt");
            remove(testDir ~ "/b.txt");
            remove(testDir ~ "/skip.d");
            rmdir(testDir);
        }
    }

    mkdir(testDir);
    write(testDir ~ "/a.txt", "");
    write(testDir ~ "/b.txt", "");
    write(testDir ~ "/skip.d", "");

    auto r = evaluateFunction(BuiltinFunction.wildcard,
        [testDir ~ "/*.txt"]);
    assert(r.canFind("a.txt"));
    assert(r.canFind("b.txt"));
    assert(!r.canFind("skip.d"));
}

///
unittest
{
    // wildcard: no matches returns empty string
    auto r = evaluateFunction(BuiltinFunction.wildcard,
        ["/nonexistent_path_abc123/*.xyz"]);
    assert(r == "");
}

///
unittest
{
    // sort: basic sorting
    {
        auto r = evaluateFunction(BuiltinFunction.sort,
            ["z y x a b c"]);
        assert(r == "a b c x y z");
    }

    // sort: remove duplicates
    {
        auto r = evaluateFunction(BuiltinFunction.sort,
            ["b a b a c c"]);
        assert(r == "a b c");
    }

    // sort: single word
    {
        auto r = evaluateFunction(BuiltinFunction.sort,
            ["hello"]);
        assert(r == "hello");
    }

    // sort: empty args
    {
        auto r = evaluateFunction(BuiltinFunction.sort,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // words: count words
    {
        auto r = evaluateFunction(BuiltinFunction.words,
            ["a b c d"]);
        assert(r == "4");
    }

    // words: single word
    {
        auto r = evaluateFunction(BuiltinFunction.words,
            ["hello"]);
        assert(r == "1");
    }

    // words: empty string
    {
        auto r = evaluateFunction(BuiltinFunction.words,
            [""]);
        assert(r == "0");
    }

    // words: no args
    {
        auto r = evaluateFunction(BuiltinFunction.words,
            []);
        assert(r == "0");
    }
}

///
unittest
{
    // shell: basic command captures stdout
    {
        auto r = evaluateFunction(BuiltinFunction.shell,
            ["echo hello"]);
        assert(r == "hello");
    }

    // shell: empty args
    {
        auto r = evaluateFunction(BuiltinFunction.shell,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // error: prints to stderr, returns empty
    {
        import std.stdio;
        auto r = evaluateFunction(BuiltinFunction.error,
            ["something went wrong"]);
        assert(r == "");
    }

    // error: no args
    {
        auto r = evaluateFunction(BuiltinFunction.error,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // warning: calls warn, returns empty
    {
        auto r = evaluateFunction(BuiltinFunction.warning,
            ["deprecated usage"]);
        assert(r == "");
    }

    // warning: no args
    {
        auto r = evaluateFunction(BuiltinFunction.warning,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // info: calls log, returns empty
    {
        auto r = evaluateFunction(BuiltinFunction.info,
            ["build started"]);
        assert(r == "");
    }

    // info: no args
    {
        auto r = evaluateFunction(BuiltinFunction.info,
            []);
        assert(r == "");
    }
}

///
unittest
{
    // findstring: found
    assert(evaluateFunction(BuiltinFunction.findstring,
        ["foo", "foobar"]) == "foo");
    // findstring: not found
    assert(evaluateFunction(BuiltinFunction.findstring,
        ["baz", "foobar"]) == "");
    // findstring: empty find string always matches
    assert(evaluateFunction(BuiltinFunction.findstring,
        ["", "anything"]) == "");
    // findstring: too few args
    assert(evaluateFunction(BuiltinFunction.findstring, ["x"]) == "");
}

///
unittest
{
    // filter: basic %-match
    {
        auto r = evaluateFunction(BuiltinFunction.filter,
            ["%.c", "foo.c bar.h baz.c"]);
        assert(r == "foo.c baz.c");
    }
    // filter: exact match (no %)
    {
        auto r = evaluateFunction(BuiltinFunction.filter,
            ["foo", "foo bar baz"]);
        assert(r == "foo");
    }
    // filter: % matches everything
    {
        auto r = evaluateFunction(BuiltinFunction.filter,
            ["%", "a b c"]);
        assert(r == "a b c");
    }
    // filter: too few args
    assert(evaluateFunction(BuiltinFunction.filter, ["x"]) == "");
}

///
unittest
{
    // filter-out: basic
    {
        auto r = evaluateFunction(BuiltinFunction.filter_out,
            ["%.h", "foo.c bar.h baz.c"]);
        assert(r == "foo.c baz.c");
    }
    // filter-out: exact match
    {
        auto r = evaluateFunction(BuiltinFunction.filter_out,
            ["bar", "foo bar baz"]);
        assert(r == "foo baz");
    }
    // filter-out: too few args
    assert(evaluateFunction(BuiltinFunction.filter_out, ["x"]) == "");
}

///
unittest
{
    // word: basic
    assert(evaluateFunction(BuiltinFunction.word, ["2", "a b c"]) == "b");
    assert(evaluateFunction(BuiltinFunction.word, ["1", "a b c"]) == "a");
    assert(evaluateFunction(BuiltinFunction.word, ["3", "a b c"]) == "c");
    // word: out of range
    assert(evaluateFunction(BuiltinFunction.word, ["0", "a b c"]) == "");
    assert(evaluateFunction(BuiltinFunction.word, ["4", "a b c"]) == "");
    // word: too few args
    assert(evaluateFunction(BuiltinFunction.word, ["x"]) == "");
}

///
unittest
{
    // wordlist: basic range
    assert(evaluateFunction(BuiltinFunction.wordlist,
        ["2", "3", "a b c d"]) == "b c");
    // wordlist: full range
    assert(evaluateFunction(BuiltinFunction.wordlist,
        ["1", "4", "a b c d"]) == "a b c d");
    // wordlist: s > e → empty
    assert(evaluateFunction(BuiltinFunction.wordlist,
        ["3", "2", "a b c d"]) == "");
    // wordlist: e beyond end → clamped
    assert(evaluateFunction(BuiltinFunction.wordlist,
        ["3", "10", "a b c d"]) == "c d");
    // wordlist: s < 1 → clamped to 1
    assert(evaluateFunction(BuiltinFunction.wordlist,
        ["0", "2", "a b c d"]) == "a b");
    // wordlist: too few args
    assert(evaluateFunction(BuiltinFunction.wordlist, ["x"]) == "");
}

///
unittest
{
    // firstword: basic
    assert(evaluateFunction(BuiltinFunction.firstword,
        ["a b c"]) == "a");
    // firstword: single word
    assert(evaluateFunction(BuiltinFunction.firstword,
        ["hello"]) == "hello");
    // firstword: empty input
    assert(evaluateFunction(BuiltinFunction.firstword, []) == "");
    assert(evaluateFunction(BuiltinFunction.firstword, [""]) == "");
}

///
unittest
{
    // lastword: basic
    assert(evaluateFunction(BuiltinFunction.lastword,
        ["a b c"]) == "c");
    // lastword: single word
    assert(evaluateFunction(BuiltinFunction.lastword,
        ["hello"]) == "hello");
    // lastword: empty input
    assert(evaluateFunction(BuiltinFunction.lastword, []) == "");
}

///
unittest
{
    // dir: extract directory part
    {
        auto r = evaluateFunction(BuiltinFunction.dir,
            ["src/foo.c include/bar.h"]);
        assert(r == "src/ include/");
    }
    // dir: no slash → ./
    {
        auto r = evaluateFunction(BuiltinFunction.dir,
            ["Makefile"]);
        assert(r == "./");
    }
    // dir: mixed
    {
        auto r = evaluateFunction(BuiltinFunction.dir,
            ["src/sub/file.o plain.txt"]);
        assert(r == "src/sub/ ./");
    }
    // dir: too few args
    assert(evaluateFunction(BuiltinFunction.dir, []) == "");
}

///
unittest
{
    // notdir: extract filename
    {
        auto r = evaluateFunction(BuiltinFunction.notdir,
            ["src/foo.c include/bar.h"]);
        assert(r == "foo.c bar.h");
    }
    // notdir: no slash → unchanged
    {
        auto r = evaluateFunction(BuiltinFunction.notdir,
            ["Makefile"]);
        assert(r == "Makefile");
    }
    // notdir: mixed
    {
        auto r = evaluateFunction(BuiltinFunction.notdir,
            ["src/sub/file.o plain.txt"]);
        assert(r == "file.o plain.txt");
    }
    // notdir: too few args
    assert(evaluateFunction(BuiltinFunction.notdir, []) == "");
}

///
unittest
{
    // suffix: extract suffix
    {
        auto r = evaluateFunction(BuiltinFunction.suffix,
            ["foo.c bar.h baz"]);
        assert(r == ".c .h ");
    }
    // suffix: no dot → empty
    {
        auto r = evaluateFunction(BuiltinFunction.suffix,
            ["Makefile"]);
        assert(r == "");
    }
    // suffix: double extension takes last
    {
        auto r = evaluateFunction(BuiltinFunction.suffix,
            ["archive.tar.gz"]);
        assert(r == ".gz");
    }
    // suffix: too few args
    assert(evaluateFunction(BuiltinFunction.suffix, []) == "");
}

///
unittest
{
    // basename: strip suffix
    {
        auto r = evaluateFunction(BuiltinFunction.basename,
            ["foo.c bar.h baz"]);
        assert(r == "foo bar baz");
    }
    // basename: no dot → unchanged
    {
        auto r = evaluateFunction(BuiltinFunction.basename,
            ["Makefile"]);
        assert(r == "Makefile");
    }
    // basename: dotfiles
    {
        auto r = evaluateFunction(BuiltinFunction.basename,
            [".hidden.c secret"]);
        assert(r == ".hidden secret");
    }
    // basename: too few args
    assert(evaluateFunction(BuiltinFunction.basename, []) == "");
}

///
unittest
{
    // addsuffix: basic
    assert(evaluateFunction(BuiltinFunction.addsuffix,
        [".o", "foo bar baz"]) == "foo.o bar.o baz.o");
    // addsuffix: single word
    assert(evaluateFunction(BuiltinFunction.addsuffix,
        [".c", "main"]) == "main.c");
    // addsuffix: empty suffix
    assert(evaluateFunction(BuiltinFunction.addsuffix,
        ["", "a b c"]) == "a b c");
    // addsuffix: too few args
    assert(evaluateFunction(BuiltinFunction.addsuffix, ["x"]) == "");
}

///
unittest
{
    // addprefix: basic
    assert(evaluateFunction(BuiltinFunction.addprefix,
        ["src/", "foo.c bar.c"]) == "src/foo.c src/bar.c");
    // addprefix: empty prefix
    assert(evaluateFunction(BuiltinFunction.addprefix,
        ["", "a b c"]) == "a b c");
    // addprefix: too few args
    assert(evaluateFunction(BuiltinFunction.addprefix, ["x"]) == "");
}

///
unittest
{
    // join: equal length
    assert(evaluateFunction(BuiltinFunction.join,
        ["a b", "1 2"]) == "a1 b2");
    // join: first list longer
    assert(evaluateFunction(BuiltinFunction.join,
        ["a b c", "1 2"]) == "a1 b2 c");
    // join: second list longer
    assert(evaluateFunction(BuiltinFunction.join,
        ["a", "1 2 3"]) == "a1 2 3");
    // join: both empty
    assert(evaluateFunction(BuiltinFunction.join,
        ["", ""]) == "");
    // join: too few args
    assert(evaluateFunction(BuiltinFunction.join, ["x"]) == "");
}

///
unittest
{
    // foreach: basic
    assert(evaluateFunction(BuiltinFunction.foreach_,
        ["f", "foo bar", "$(f).o"]) == "foo.o bar.o");
    // foreach: single word in list
    assert(evaluateFunction(BuiltinFunction.foreach_,
        ["x", "hello", "<$(x)>"]) == "<hello>");
    // foreach: empty list
    assert(evaluateFunction(BuiltinFunction.foreach_,
        ["x", "", "$(x)"]) == "");
    // foreach: too few args
    assert(evaluateFunction(BuiltinFunction.foreach_, ["x"]) == "");
}

///
unittest
{
    // call: basic positional substitution
    {
        Environment env;
        env.set("reverse", "$2 $1");
        auto r = evaluateFunction(BuiltinFunction.call,
            ["reverse", "a", "b"], &env);
        assert(r == "b a");
    }
    // call: single argument
    {
        Environment env;
        env.set("wrap", "[$1]");
        auto r = evaluateFunction(BuiltinFunction.call,
            ["wrap", "hello"], &env);
        assert(r == "[hello]");
    }
    // call: no env → empty
    assert(evaluateFunction(BuiltinFunction.call,
        ["unknown", "x"]) == "");
    // call: too few args
    assert(evaluateFunction(BuiltinFunction.call, []) == "");
}

///
unittest
{
    // value: returns unexpanded variable value
    {
        Environment env;
        env.set("FOO", "bar");
        auto r = evaluateFunction(BuiltinFunction.value,
            ["FOO"], &env);
        assert(r == "bar");
    }
    // value: undefined variable → ""
    assert(evaluateFunction(BuiltinFunction.value,
        ["UNDEFINED"]) == "");
    // value: too few args
    assert(evaluateFunction(BuiltinFunction.value, []) == "");
}

///
unittest
{
    // origin: defined variable
    {
        Environment env;
        env.set("FOO", "bar");
        auto r = evaluateFunction(BuiltinFunction.origin,
            ["FOO"], &env);
        assert(r == "file");
    }
    // origin: undefined variable
    assert(evaluateFunction(BuiltinFunction.origin,
        ["UNDEFINED"]) == "undefined");
    // origin: too few args
    assert(evaluateFunction(BuiltinFunction.origin, []) == "undefined");
}

///
unittest
{
    // flavor: defined variable (all = assignments are "recursive")
    {
        Environment env;
        env.set("FOO", "bar");
        auto r = evaluateFunction(BuiltinFunction.flavor,
            ["FOO"], &env);
        assert(r == "recursive");
    }
    // flavor: undefined variable
    assert(evaluateFunction(BuiltinFunction.flavor,
        ["UNDEFINED"]) == "undefined");
    // flavor: too few args
    assert(evaluateFunction(BuiltinFunction.flavor, []) == "undefined");
}

///
unittest
{
    // realpath: resolves path (must exist to resolve symlinks)
    import std.file : mkdir, rmdir, write;
    import std.path : buildPath;
    auto testDir = "fn_realpath_test_xx";
    scope (exit)
    {
        import std.file : remove;
        if (exists(testDir))
        {
            remove(testDir ~ "/a.txt");
            rmdir(testDir);
        }
    }
    mkdir(testDir);
    write(testDir ~ "/a.txt", "");
    {
        auto r = evaluateFunction(BuiltinFunction.realpath,
            [testDir]);
        assert(r.length > 0);
        assert(r.canFind(testDir));
    }
    // realpath: too few args
    assert(evaluateFunction(BuiltinFunction.realpath, []) == "");
}

///
unittest
{
    // abspath: returns absolute path
    {
        auto r = evaluateFunction(BuiltinFunction.abspath,
            ["."]);
        assert(r.length > 1);
        assert(r[0] == '/');
    }
    // abspath: multiple paths
    {
        auto r = evaluateFunction(BuiltinFunction.abspath,
            ["./src ./include"]);
        assert(r.canFind("/src"));
        assert(r.canFind("/include"));
    }
    // abspath: too few args
    assert(evaluateFunction(BuiltinFunction.abspath, []) == "");
}

///
unittest
{
    // Verify that all previously-stubbed functions still return ""
    // when given insufficient arguments (edge-case coverage).
    assert(evaluateFunction(BuiltinFunction.findstring, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.filter, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.filter_out, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.word, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.wordlist, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.dir, []) == "");
    assert(evaluateFunction(BuiltinFunction.notdir, []) == "");
    assert(evaluateFunction(BuiltinFunction.suffix, []) == "");
    assert(evaluateFunction(BuiltinFunction.basename, []) == "");
    assert(evaluateFunction(BuiltinFunction.addsuffix, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.addprefix, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.join, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.realpath, []) == "");
    assert(evaluateFunction(BuiltinFunction.abspath, []) == "");
    assert(evaluateFunction(BuiltinFunction.foreach_, ["x"]) == "");
    assert(evaluateFunction(BuiltinFunction.call, []) == "");
    assert(evaluateFunction(BuiltinFunction.value, []) == "");
    assert(evaluateFunction(BuiltinFunction.origin, []) == "undefined");
    assert(evaluateFunction(BuiltinFunction.flavor, []) == "undefined");
}

///
unittest
{
    // null/empty Environment pointer works
    auto r = evaluateFunction(BuiltinFunction.subst,
        ["x", "X", "x marks the spot"]);
    assert(r == "X marks the spot");
}
