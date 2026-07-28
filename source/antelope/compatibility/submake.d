/// GNU Make sub-make and recursive make communication.
///
/// GNU Make has specific protocols for communicating between parent and
/// child make processes: MAKEFLAGS, MAKE, variable export/unexport,
/// and the jobserver (--jobserver-style pipe).
///
/// This module handles:
///   - $(MAKE) / $(MAKECMDGOALS) propagation
///   - MAKEFLAGS / GNUMAKEFLAGS serialization
///   - Variable export to sub-makes
///   - Jobserver pipe inheritance (--jobserver-style)
module antelope.compatibility.submake;

import antelope.cli.args;
import std.conv : to;
import std.string : strip;
import std.string : strip;

/// Sub-make communication options.
struct SubMakeConfig
{
    /// Serialize and pass MAKEFLAGS.
    bool passMakeFlags = true;
    /// Pass jobserver file descriptors.
    bool passJobserver = true;
    /// Export variables marked with `export`.
    bool respectExportDirective = true;
    /// Track recursion depth to avoid infinite loops.
    uint maxRecursionDepth = 10;
}

/// Serialize MAKEFLAGS for a sub-make invocation.
///
/// Builds a space-separated string of GNU Make-compatible flags from the
/// current CLI configuration.  The resulting string can be set as the
/// MAKEFLAGS environment variable for recursive $(MAKE) invocations.
///
/// Serialized flags:
///   -j<N>   — parallel job count (only when jobs > 1)
///   -n       — dry run
///   -P       — POSIX conformance mode
///   -d       — debug output
///   VAR=val  — command-line variable overrides
///
/// Returns: a space-delimited MAKEFLAGS string, or "" if no flags are active.
string serializeMakeFlags(CliConfig config)
{
    string flags;

    // Variable overrides first (parsed back by parseArgs in sub-make)
    foreach (varName, varValue; config.varOverrides)
        flags ~= " " ~ varName ~ "=" ~ varValue;

    if (config.jobs > 1)
        flags ~= " -j" ~ config.jobs.to!string;
    if (config.dryRun)
        flags ~= " -n";
    if (config.posix)
        flags ~= " -P";
    if (config.debugMode)
        flags ~= " -d";
    return flags.strip;
}
