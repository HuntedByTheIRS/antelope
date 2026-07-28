/// File discovery and globbing utilities.
module antelope.filesystem.files;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.string;

/// Find files matching a glob pattern.
///
/// Supports `*` (single-directory wildcard) and `**` (recursive wildcard).
///
/// Examples:
/// ---
/// glob("*.d")           // all D files in current directory
/// glob("src/**/*.d")    // all D files under src/ recursively
/// glob("**")            // all files recursively from current directory
/// ---
///
/// Returns a sorted array of relative paths, or an empty array if no
/// matches are found or the directory does not exist.
string[] glob(string pattern)
{
    string dir;
    string filePattern;
    SpanMode mode;

    auto doubleStar = pattern.indexOf("**");
    if (doubleStar >= 0)
    {
        // Extract directory prefix before **
        dir = pattern[0 .. doubleStar];
        if (dir.length == 0)
            dir = ".";
        else if (dir[$ - 1] == '/' || dir[$ - 1] == '\\')
            dir = dir[0 .. $ - 1];

        // Extract file pattern after **/
        filePattern = pattern[doubleStar + 2 .. $];
        while (filePattern.length > 0
               && (filePattern[0] == '/' || filePattern[0] == '\\'))
            filePattern = filePattern[1 .. $];

        // Bare ** matches everything recursively
        if (filePattern.length == 0)
            filePattern = "*";

        mode = SpanMode.depth;
    }
    else
    {
        dir = pattern.dirName();
        if (dir.length == 0)
            dir = ".";
        filePattern = pattern.baseName();
        mode = SpanMode.shallow;

        // When directory contains wildcards (e.g., "src/*"),
        // dirEntries can't use them as literal paths.
        // Fall back to depth-scan from the last non-wildcard base.
        if (dir.indexOf('*') >= 0 || dir.indexOf('?') >= 0)
        {
            // Find the last component before any wildcard
            import std.path : dirSeparator;
            auto slash = dir.lastIndexOf('/');
            if (slash < 0) slash = dir.lastIndexOf('\\');
            string baseDir = (slash < 0) ? "." : dir[0 .. slash];
            if (baseDir.length == 0) baseDir = ".";

            // Use depth scan from base, filter by filename pattern
            mode = SpanMode.depth;
            dir = baseDir;
            // filePattern already set to basename (e.g., "*.c")
        }
    }

    try
    {
        auto entries = dirEntries(dir, filePattern, mode)
            .map!(e => e.name)
            .array;
        sort(entries);
        return entries;
    }
    catch (Exception)
    {
        return [];
    }
}

// Coverage for glob function.
unittest
{
    import std.file : mkdir, rmdir, remove;
    import std.path : buildPath;

    auto testDir = "glob_test_temp_xx";

    // Ensure clean state.
    scope (exit)
    {
        if (exists(buildPath(testDir, "sub")))
            rmdir(buildPath(testDir, "sub"));
        if (exists(testDir))
            rmdir(testDir);
    }

    mkdir(testDir);
    std.file.write(buildPath(testDir, "foo.d"), "");
    std.file.write(buildPath(testDir, "bar.d"), "");
    std.file.write(buildPath(testDir, "baz.txt"), "");

    mkdir(buildPath(testDir, "sub"));
    std.file.write(buildPath(testDir, "sub", "qux.d"), "");

    // Shallow glob — matches *.d in test dir only.
    auto dFiles = glob(buildPath(testDir, "*.d"));
    assert(dFiles.length == 2);
    assert(dFiles.canFind(buildPath(testDir, "foo.d")));
    assert(dFiles.canFind(buildPath(testDir, "bar.d")));

    // Recursive glob — matches all .d files under test dir.
    auto allDFiles = glob(buildPath(testDir, "**/*.d"));
    assert(allDFiles.length == 3);
    assert(allDFiles.canFind(buildPath(testDir, "sub", "qux.d")));

    // No matches returns empty array.
    auto noMatch = glob(buildPath(testDir, "*.xyz"));
    assert(noMatch.length == 0);

    // Nonexistent directory returns empty array.
    auto badDir = glob(buildPath("nonexistent_dir_abcdef", "*.d"));
    assert(badDir.length == 0);

    // Clean up test files.
    remove(buildPath(testDir, "foo.d"));
    remove(buildPath(testDir, "bar.d"));
    remove(buildPath(testDir, "baz.txt"));
    remove(buildPath(testDir, "sub", "qux.d"));
    rmdir(buildPath(testDir, "sub"));
    rmdir(testDir);
}
