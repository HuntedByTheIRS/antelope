/// File timestamp comparison for out-of-date detection.
module antelope.filesystem.timestamps;

import std.file;
import std.datetime;
import antelope.compatibility.vpath;

/// Get the last-modified time of a file as a Unix timestamp.
///
/// Returns: The modification time in seconds since the Unix epoch
///          (1970-01-01T00:00:00Z), or -1 if the file does not
///          exist or cannot be accessed (e.g., permission denied).
long getTimestamp(string path)
{
    try
    {
        auto mtime = timeLastModified(path);
        return mtime.toUnixTime();
    }
    catch (FileException)
    {
        return -1;
    }
}

/// Determine whether a target needs to be rebuilt based on its
/// prerequisites.
///
/// A target is considered out of date (returning true) when:
///   - It is listed in the phonyTargets set (always rebuild).
///   - The target file does not exist.
///   - Any prerequisite file does not exist (after VPATH search).
///   - Any prerequisite has a newer timestamp than the target.
///
/// Order-only prerequisites (those after `|` in the rule) are NOT
/// checked for timestamps — they must exist but their modification
/// time does not trigger a rebuild.
///
/// Params:
///   target            = The file or phony target to check.
///   prerequisites     = List of prerequisite file paths.
///   phonySet          = Optional set of phony target names (may be null).
///   vpath             = Optional VPATH config for prerequisite search (may be null).
///   orderOnlyPrereqs  = Optional list of order-only prereqs to skip (may be null).
///
/// Returns: true if the target needs to be rebuilt, false otherwise.
bool needsRebuild(string target, string[] prerequisites,
                  const bool[string]* phonySet = null,
                  const(VPathConfig)* vpathConfig = null,
                  const string[]* orderOnlyPrereqs = null)
{
    // Phony targets always need rebuilding.
    if (phonySet !is null && (target in *phonySet) !is null)
        return true;

    auto targetTime = getTimestamp(target);

    // Non-existent target must be built.
    if (targetTime == -1)
        return true;

    foreach (prereq; prerequisites)
    {
        // Skip order-only prerequisites — they must exist but their
        // timestamps should NOT trigger a rebuild.
        if (orderOnlyPrereqs !is null)
        {
            bool isOrderOnly;
            foreach (oo; *orderOnlyPrereqs)
            {
                if (prereq == oo)
                {
                    isOrderOnly = true;
                    break;
                }
            }
            if (isOrderOnly)
                continue;
        }

        // Try VPATH resolution if config provided
        string resolved = prereq;
        if (vpathConfig !is null)
            resolved = vpathResolve(prereq, *vpathConfig);

        auto prereqTime = getTimestamp(resolved);

        // Missing prerequisite forces a rebuild.
        if (prereqTime == -1)
            return true;

        // Prerequisite newer than target → out of date.
        if (prereqTime > targetTime)
            return true;
    }

    return false;
}

// unittest
unittest
{
    // getTimestamp returns -1 for non-existent files
    assert(getTimestamp("/nonexistent_path_xyz_antelope_test") == -1);

    // needsRebuild for non-existent target
    assert(needsRebuild("/nonexistent_target_antelope_test", []));

    // needsRebuild for phony target (using local phony set)
    bool[string] phonySet = ["testPhony_antelope": true];
    assert(needsRebuild("testPhony_antelope", [], &phonySet));

    // needsRebuild with missing prerequisite
    assert(needsRebuild("/nonexistent_target_foo", ["/nonexistent_prereq_bar"]));
}
