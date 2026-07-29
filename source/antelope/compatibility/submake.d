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
///   -j<N>              — parallel job count (only when jobs > 1)
///   -n                  — dry run
///   -P                  — POSIX conformance mode
///   -d                  — debug output
///   --jobserver-auth=R,W — jobserver pipe file descriptors (when provided)
///   VAR=val             — command-line variable overrides
///
/// Returns: a space-delimited MAKEFLAGS string, or "" if no flags are active.
string serializeMakeFlags(CliConfig config)
{
    return serializeMakeFlagsImpl(config, 0, 0);
}

/// Serialize MAKEFLAGS including jobserver pipe descriptors.
///
/// When `readFd` and `writeFd` are non-zero, appends
/// `--jobserver-auth=<readFd>,<writeFd>` to the MAKEFLAGS string
/// so sub-make processes can participate in the shared job pool.
string serializeMakeFlags(CliConfig config, int readFd, int writeFd)
{
    return serializeMakeFlagsImpl(config, readFd, writeFd);
}

private string serializeMakeFlagsImpl(CliConfig config, int readFd, int writeFd)
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

    // Jobserver pipe file descriptors for recursive make coordination.
    // Only included when the pool has created a jobserver pipe.
    if (readFd > 0 && writeFd > 0)
    {
        import std.conv : to;
        flags ~= " --jobserver-auth=" ~ readFd.to!string ~ "," ~ writeFd.to!string;
    }

    return flags.strip;
}
