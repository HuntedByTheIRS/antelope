/// GNU Make include directive handling.
///
/// GNU Make supports three forms of the include directive:
///   include filename       — error if missing
///   -include filename      — warn (not error) if missing
///   sinclude filename      — same as -include (POSIX compat)
///
/// Included files are read, parsed, and their rules merged into the current
/// makefile. If a missing included file can be rebuilt from an implicit rule,
/// GNU Make will rebuild it and restart.
module antelope.compatibility.include_handling;

/// How a missing include file is handled.
enum IncludeFailureMode
{
    /// include — error out.
    fatal,
    /// -include / sinclude — warn and continue.
    ignore,
}

/// An include directive parsed from a Makefile.
struct IncludeDirective
{
    string[] files;
    IncludeFailureMode onFailure;
}

/// Try to resolve an include file (VPATH, implicit rule, restart).
string resolveInclude(string filename)
{
    return filename;
}
