/// Conditional evaluation (ifeq/ifneq/ifdef/ifndef).
///
/// Evaluates GNU Make conditional expressions at parse/evaluate time.
/// Supports three syntactic forms:
///   - Parenthesized: `ifeq (a, b)`
///   - Quoted:       `ifeq "a" "b"`
///   - Bare:         `ifdef VAR_NAME`
module antelope.evaluator.conditionals;

import antelope.shell.environment;
import std.string : strip, indexOf;
import std.ascii : isWhite;

/// Evaluate a GNU Make conditional expression.
///
/// Params:
///   op  = conditional operator: "ifeq", "ifneq", "ifdef", or "ifndef"
///   lhs = left-hand argument (for paren form `ifeq (a, b)`,
///         lhs contains `(a, b)` and rhs is empty)
///   rhs = right-hand argument (empty for ifdef/ifndef and paren form)
///   env = optional Environment pointer for ifdef/ifndef variable lookups
///
/// Returns: true if the condition holds, false otherwise.
bool evaluateConditional(string op, string lhs, string rhs,
    Environment* env = null)
{
    switch (op)
    {
        case "ifeq":
        {
            string a, b;
            splitArgs(lhs, rhs, a, b);
            // Expand variable references before comparison (GNU Make behavior)
            if (env !is null)
            {
                import antelope.evaluator.expansion;
                a = expand(a, env);
                b = expand(b, env);
            }
            return a == b;
        }

        case "ifneq":
        {
            string a, b;
            splitArgs(lhs, rhs, a, b);
            if (env !is null)
            {
                import antelope.evaluator.expansion;
                a = expand(a, env);
                b = expand(b, env);
            }
            return a != b;
        }

        case "ifdef":
        {
            auto key = stripQuotes(lhs.strip);
            return (env !is null) && env.hasKey(key);
        }

        case "ifndef":
        {
            auto key = stripQuotes(lhs.strip);
            return (env is null) || !env.hasKey(key);
        }

        default:
            return false;
    }
}

/// Split conditional arguments handling both parenthesized and
/// two-argument forms.
///
/// **Parenthesized form:**  `ifeq (a, b)`
///   - `lhs` = `(a, b)`, `rhs` = `""`
///   - Strips parens, splits on the first comma, strips whitespace
///     and surrounding quotes from each part.
///
/// **Two-argument form:** `ifeq "a" "b"` or `ifeq a b`
///   - Both `lhs` and `rhs` are provided.
///   - Strips whitespace and surrounding quotes from each.
private void splitArgs(string lhs, string rhs, out string a,
    out string b)
{
    // Paren form: ifeq (a, b)
    if (lhs.length > 0 && lhs[0] == '(')
    {
        auto inner = lhs[1 .. $].strip;
        // Strip closing paren
        if (inner.length > 0 && inner[$ - 1] == ')')
            inner = inner[0 .. $ - 1].strip;

        auto comma = indexOf(inner, ',');
        if (comma >= 0)
        {
            a = stripQuotes(inner[0 .. comma].strip);
            b = stripQuotes(inner[comma + 1 .. $].strip);
        }
        else
        {
            // No comma — entire inner is a (malformed but handle gracefully)
            a = stripQuotes(inner.strip);
            b = "";
        }
    }
    // Two-argument form: ifeq "a" "b" or ifeq a b
    else
    {
        a = stripQuotes(lhs.strip);
        b = stripQuotes(rhs.strip);
    }
}

/// Strip matching quote characters (" or ') from both ends of a string.
private string stripQuotes(string s)
{
    if (s.length >= 2)
    {
        if ((s[0] == '"' && s[$ - 1] == '"')
            || (s[0] == '\'' && s[$ - 1] == '\''))
            return s[1 .. $ - 1];
    }
    return s;
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

unittest
{
    import std.stdio : writeln;

    // --- ifeq simple ---
    assert(evaluateConditional("ifeq", "a", "a"),
        "ifeq: 'a' == 'a' should be true");
    assert(!evaluateConditional("ifeq", "a", "b"),
        "ifeq: 'a' == 'b' should be false");

    // --- ifeq with double quotes ---
    assert(evaluateConditional("ifeq", `"a"`, `"a"`),
        "ifeq: '\"a\"' == '\"a\"' should be true");
    assert(!evaluateConditional("ifeq", `"a"`, `"b"`),
        "ifeq: '\"a\"' == '\"b\"' should be false");

    // --- ifeq with single quotes ---
    assert(evaluateConditional("ifeq", "'a'", "'a'"),
        "ifeq: single-quoted equal should be true");

    // --- ifneq ---
    assert(evaluateConditional("ifneq", "a", "b"),
        "ifneq: 'a' != 'b' should be true");
    assert(!evaluateConditional("ifneq", "a", "a"),
        "ifneq: 'a' != 'a' should be false");

    // --- Paren form: ifeq (a, b)  ---
    assert(evaluateConditional("ifeq", "(a, a)", ""),
        "ifeq paren form: (a, a) should be true");
    assert(!evaluateConditional("ifeq", "(a, b)", ""),
        "ifeq paren form: (a, b) should be false");

    // --- Paren form with whitespace ---
    assert(evaluateConditional("ifeq", "(  a  ,  a  )", ""),
        "ifeq paren form with whitespace should be true");

    // --- Quoted form with whitespace ---
    assert(evaluateConditional("ifeq", `"  a  "`, `"  a  "`),
        "ifeq quoted with internal whitespace should be true");

    // --- ifdef / ifndef with Environment ---
    Environment env;
    env.set("EXISTING_VAR", "value");
    env.set("ANOTHER_VAR", "42");

    assert(evaluateConditional("ifdef", "EXISTING_VAR", "", &env),
        "ifdef: EXISTING_VAR exists should be true");
    assert(!evaluateConditional("ifdef", "NONEXISTENT_VAR", "", &env),
        "ifdef: NONEXISTENT_VAR missing should be false");
    assert(!evaluateConditional("ifndef", "EXISTING_VAR", "", &env),
        "ifndef: EXISTING_VAR exists should be false");
    assert(evaluateConditional("ifndef", "NONEXISTENT_VAR", "", &env),
        "ifndef: NONEXISTENT_VAR missing should be true");

    // --- ifdef with null env (no environment passed) ---
    assert(!evaluateConditional("ifdef", "ANYTHING", ""),
        "ifdef: null env should return false");
    assert(evaluateConditional("ifndef", "ANYTHING", ""),
        "ifndef: null env should return true");

    // --- Mixed: ifneq with paren form ---
    assert(evaluateConditional("ifneq", "(a, b)", ""),
        "ifneq paren form: (a, b) should be true");
    assert(!evaluateConditional("ifneq", "(a, a)", ""),
        "ifneq paren form: (a, a) should be false");

    // --- Empty strings ---
    assert(evaluateConditional("ifeq", "", ""),
        "ifeq: empty == empty should be true");
    assert(!evaluateConditional("ifeq", "", "x"),
        "ifeq: empty != x should be false");

    writeln("All conditional evaluation tests passed.");
}
