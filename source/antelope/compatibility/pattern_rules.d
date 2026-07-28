/// GNU Make pattern rules and static pattern rules.
///
/// Pattern rules are GNU Make's primary mechanism for implicit and
/// static-pattern compilation rules. This module covers the matching
/// algorithm, stem extraction, order of precedence, and cancellation
/// (matching a rule with no recipe removes it).
module antelope.compatibility.pattern_rules;

import antelope.build.target;
import std.string : indexOf;

/// A pattern rule: %.o → %.c via recipe.
struct PatternRule
{
    string targetPattern;   /// e.g. "%.o"
    string[] prereqPatterns; /// e.g. ["%.c"]
    string[] recipe;
    bool terminal;          /// true = cancels inherited rules
}

/// Result of matching a pattern rule against a target.
struct PatternMatch
{
    PatternRule rule;
    string stem;            /// The matched wildcard portion.
    string[] resolvedPrereqs;
}

/// Find all pattern rules matching a target, ordered by GNU Make priority.
///
/// Checks against user-defined pattern rules stored in the list.
/// Pattern: "%.o" matches "foo.o", extracting stem "foo".
PatternMatch[] matchPatternRules(string target, PatternRule[] userRules)
{
    PatternMatch[] matches;
    foreach (ref rule; userRules)
    {
        if (rule.targetPattern.length == 0)
            continue;
        auto pct = indexOf(rule.targetPattern, '%');
        if (pct < 0)
            continue;
        string prefix = rule.targetPattern[0 .. pct];
        string suffix = rule.targetPattern[pct + 1 .. $];

        // Must have at least one char for the stem
        if (target.length < prefix.length + suffix.length + 1)
            continue;
        if (prefix.length > 0 && target[0 .. prefix.length] != prefix)
            continue;
        if (suffix.length > 0 && target[$ - suffix.length .. $] != suffix)
            continue;

        // Extract stem and resolve prereqs
        string stem = target[prefix.length .. target.length - suffix.length];
        PatternMatch m;
        m.rule = rule;
        m.stem = stem;
        m.resolvedPrereqs = [];
        foreach (pp; rule.prereqPatterns)
        {
            auto pct2 = indexOf(pp, '%');
            if (pct2 >= 0)
                m.resolvedPrereqs ~= pp[0 .. pct2] ~ stem ~ pp[pct2 + 1 .. $];
            else
                m.resolvedPrereqs ~= pp;
        }
        matches ~= m;
        if (rule.terminal)
            break;
    }
    return matches;
}

/// Check if a target name contains a % wildcard (i.e., is a pattern rule).
bool isPatternTarget(string name)
{
    import std.string : indexOf;
    return indexOf(name, '%') >= 0;
}

/// Create a PatternRule from a Target that was declared as a pattern rule
/// (target name contains '%').
PatternRule toPatternRule(Target t)
{
    PatternRule r;
    r.targetPattern = t.name;
    r.prereqPatterns = t.prerequisites;
    r.recipe = t.recipe;
    r.terminal = false;
    return r;
}
