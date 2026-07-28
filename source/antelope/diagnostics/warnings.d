/// Warning diagnostics for non-fatal issues.
module antelope.diagnostics.warnings;

import std.stdio;

/// Categories of warnings.
enum WarningKind
{
    deprecatedFeature,
    undefinedVariable,
    orderOnlyCircular,
    phonyPrerequisite,
    overrideConflict,
}

/// Whether warnings are currently enabled. Default: true.
__gshared bool warningsEnabled = true;

/// Enable or disable warnings globally.
/// Params: enabled = set to false to suppress all warning output.
void setWarningsEnabled(bool enabled)
{
    warningsEnabled = enabled;
}

/// Map a WarningKind to a human-readable string.
private string warningKindString(WarningKind kind)
{
    final switch (kind)
    {
        case WarningKind.deprecatedFeature:    return "deprecated-feature";
        case WarningKind.undefinedVariable:    return "undefined-variable";
        case WarningKind.orderOnlyCircular:    return "order-only-circular";
        case WarningKind.phonyPrerequisite:    return "phony-prerequisite";
        case WarningKind.overrideConflict:     return "override-conflict";
    }
}

/// Issue a warning with location.
/// Writes to stderr in the format: antelope: warning: <kind> <message> at <file>:<line>
/// Params:
///   kind    = the category of warning
///   message = descriptive message for the user
///   file    = source file where the warning originates (default: __FILE__)
///   line    = source line where the warning originates (default: __LINE__)
void warn(WarningKind kind, string message, string file = __FILE__, size_t line = __LINE__)
{
    if (!warningsEnabled)
        return;

    stderr.writeln("antelope: warning: ", warningKindString(kind),
                   " ", message, " at ", file, ":", line);
}

// --- Tests ---

unittest
{
    // Verify warningsEnabled guard works correctly.
    auto oldEnabled = warningsEnabled;

    // With warnings disabled, nothing should happen — just verify no crash.
    warningsEnabled = false;
    warn(WarningKind.deprecatedFeature, "should not appear", "test.d", 1);

    // Re-enable and verify a basic call doesn't throw.
    warningsEnabled = true;
    warn(WarningKind.deprecatedFeature, "test warning", "test.d", 42);
    warn(WarningKind.undefinedVariable, "undefined var", "foo.d", 10);
    warn(WarningKind.orderOnlyCircular, "circular dep", "bar.d", 5);
    warn(WarningKind.phonyPrerequisite, "phony prereq", "baz.d", 7);
    warn(WarningKind.overrideConflict, "override conflict", "qux.d", 3);

    // Restore original state.
    warningsEnabled = oldEnabled;
}
