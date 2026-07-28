/// Path resolution, normalization, and working-directory tracking.
module antelope.filesystem.paths;

import std.path : absolutePath, buildNormalizedPath;
import std.file : exists, readLink;

/// Resolve a path to its canonical absolute form.
///
/// Converts relative paths to absolute, normalizes `.` and `..` segments,
/// and resolves symlinks if the path exists. If the path does not exist,
/// returns the best-effort normalized absolute form.
///
/// Returns: The canonical absolute form of `path`.
string resolvePath(string path)
{
    // Resolve relative to working directory
    string result = absolutePath(path);

    // Normalize `.` and `..` segments
    result = buildNormalizedPath(result);

    // Resolve symlinks if the path exists
    if (exists(result))
    {
        try
        {
            result = readLink(result);
            // readLink may return a relative path; make it absolute
            result = buildNormalizedPath(absolutePath(result));
        }
        catch (Exception)
        {
            // Not a symlink or readLink failed — keep the normalized path
        }
    }

    return result;
}

///
unittest
{
    assert(resolvePath(".").length > 0);
}
