/// GNU Make VPATH / vpath directive — directory search path for prerequisites.
///
/// GNU Make supports two mechanisms for searching directories:
///   - VPATH variable: search path for all prerequisites
///   - vpath directive: search path scoped by pattern (e.g. vpath %.h src/)
///
/// This module handles both the simple variable-based and the pattern-scoped
/// search, plus the interaction with implicit rule chaining.
module antelope.compatibility.vpath;

/// A single vpath pattern → directory mapping.
struct VPathEntry
{
    string pattern;      /// e.g. "%.h" — empty for VPATH variable entries.
    string[] directories;
}

/// Complete VPATH configuration.
struct VPathConfig
{
    /// From VPATH = dir1:dir2
    string[] globalSearchDirs;
    /// From vpath %.h src/
    VPathEntry[] patternEntries;
}

/// Search for a file across all VPATH directories.
///
/// Resolution order (matching GNU Make):
///   1. Check if file exists locally → return as-is
///   2. Check pattern-specific vpath entries (if filename matches pattern)
///   3. Check global VPATH search dirs
///   4. Return original filename if not found anywhere
///
/// Params:
///   filename = The prerequisite file to search for
///   config   = VPATH configuration (global dirs + pattern entries)
///
/// Returns: The resolved path if found in a search directory, or the
///          original filename if not found anywhere.
string vpathResolve(string filename, const(VPathConfig) config)
{
    import std.file : exists;
    import std.path : buildPath;

    // Local file exists → use it directly
    if (exists(filename))
        return filename;

    // Check pattern-specific entries
    foreach (entry; config.patternEntries)
    {
        if (entry.pattern.length == 0)
            continue;
        // Simple pattern matching: if pattern is "%.h", check if filename
        // ends with ".h" (after the %)
        if (patternMatches(filename, entry.pattern))
        {
            foreach (dir; entry.directories)
            {
                string candidate = buildPath(dir, filename);
                if (exists(candidate))
                    return candidate;
            }
        }
    }

    // Check global search dirs
    foreach (dir; config.globalSearchDirs)
    {
        if (dir.length == 0)
            continue;
        string candidate = buildPath(dir, filename);
        if (exists(candidate))
            return candidate;
    }

    // Not found — return original
    return filename;
}

/// Simple pattern match: "%.h" matches "foo.h", "bar/baz.h", etc.
/// Splits pattern on '%' into prefix and suffix; checks if filename
/// starts with prefix and ends with suffix, with at least one char in between.
private bool patternMatches(string filename, string pattern)
{
    import std.string : indexOf;
    auto pct = indexOf(pattern, '%');
    if (pct < 0)
        return filename == pattern;

    string prefix = pattern[0 .. pct];
    string suffix = pattern[pct + 1 .. $];

    // Must be at least one char between prefix and suffix
    if (filename.length < prefix.length + suffix.length + 1)
        return false;

    if (prefix.length > 0 && filename[0 .. prefix.length] != prefix)
        return false;

    if (suffix.length > 0 && filename[$ - suffix.length .. $] != suffix)
        return false;

    return true;
}
