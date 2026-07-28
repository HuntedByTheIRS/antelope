/// GNU Make target-specific and pattern-specific variable assignments.
///
/// GNU Make allows variable values to be scoped to specific targets or
/// patterns, overriding global values only when building that target:
///   target: VAR = value
///   target: VAR := value
///   target: VAR ::= value
///   target: VAR += value
///   target: VAR ?= value
///   %: VAR = value  (pattern-specific)
module antelope.compatibility.target_vars;

/// The scope kind of a variable override.
enum TargetVarScope
{
    /// target: VAR = value
    targetSpecific,
    /// pattern: VAR = value
    patternSpecific,
}

/// A target-specific or pattern-specific variable assignment.
struct ScopedVariable
{
    string targetPattern;
    string name;
    string value;
    bool recursive;     /// true for =, false for :=
    TargetVarScope varScope;
}

/// Look up a variable respecting target-scoped overrides.
string lookupScopedVar(string target, string varName)
{
    return "";
}
