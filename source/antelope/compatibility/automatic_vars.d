/// GNU Make automatic variables: $@, $<, $^, $+, $*, $?, $%, $|, and their variants.
///
/// Automatic variables are set implicitly by GNU Make during rule execution.
/// This module defines them and controls when they are available, including
/// the directory/file-component variants ($(@D), $(@F), $(<D), $(<F), etc.).
module antelope.compatibility.automatic_vars;

/// All automatic variables GNU Make provides.
enum AutomaticVar
{
    /// $@  — target name.
    target,
    /// $<  — first prerequisite.
    firstPrereq,
    /// $^  — all prerequisites (deduplicated).
    allPrereqs,
    /// $+  — all prerequisites (duplicates preserved).
    allPrereqsPlus,
    /// $*  — stem from pattern match.
    stem,
    /// $?  — prerequisites newer than target.
    newerPrereqs,
    /// $%  — archive member name.
    archiveMember,
    /// $|  — order-only prerequisites.
    orderOnlyPrereqs,
}

/// Directory/file component variants for each automatic variable.
enum AutoVarComponent
    { dir, file, suffix, basename }

/// Evaluate an automatic variable, returning its string value.
///
/// Params:
///   var     = the automatic variable to resolve
///   target  = the current target name ($@)
///   prereqs = the list of prerequisites
///   stem    = the stem from pattern matching ($*)
///
/// Returns: the string value of the requested automatic variable.
string getAutomaticVar(AutomaticVar var, string target, string[] prereqs, string stem = "")
{
    import std.algorithm.iteration : filter;
    import std.array : array, join;

    final switch (var)
    {
        case AutomaticVar.target:
            return target;

        case AutomaticVar.firstPrereq:
            if (prereqs.length == 0)
                return "";
            return prereqs[0];

        case AutomaticVar.allPrereqs:
        {
            // Space-joined, duplicates removed, order preserved.
            bool[string] seen;
            string[] unique;
            foreach (p; prereqs)
            {
                if (p in seen)
                    continue;
                seen[p] = true;
                unique ~= p;
            }
            return unique.join(" ");
        }

        case AutomaticVar.allPrereqsPlus:
            // Space-joined, duplicates preserved.
            return prereqs.join(" ");

        case AutomaticVar.stem:
            return stem;

        case AutomaticVar.newerPrereqs:
            // Return all prereqs for now — timestamp filtering is delegated.
            return prereqs.join(" ");

        case AutomaticVar.archiveMember:
            // Not yet implemented.
            return "";

        case AutomaticVar.orderOnlyPrereqs:
            // Not yet implemented.
            return "";
    }
}

/// Extract the directory part of a path.
/// "src/sub/file.o" → "src/sub/"
/// "file.o"         → "./"
string dirPart(string path)
{
    import std.string : lastIndexOf;
    auto idx = path.lastIndexOf('/');
    if (idx == -1) return "./";
    return path[0 .. idx + 1];
}

/// Extract the file part (basename + suffix) of a path.
/// "src/sub/file.o" → "file.o"
/// "file.o"         → "file.o"
string filePart(string path)
{
    import std.string : lastIndexOf;
    auto idx = path.lastIndexOf('/');
    if (idx == -1) return path;
    return path[idx + 1 .. $];
}

/// Extract the basename (filename without suffix) of a path.
/// "src/sub/file.o" → "file"
/// "src/sub/file"   → "file"
/// ".hidden"        → ".hidden"
string basePart(string path)
{
    string f = filePart(path);
    import std.string : lastIndexOf;
    auto idx = f.lastIndexOf('.');
    if (idx == -1 || idx == 0) return f;
    return f[0 .. idx];
}

/// Extract the suffix (extension including dot) of a path.
/// "src/sub/file.o" → ".o"
/// "src/sub/file"   → ""
string suffixPart(string path)
{
    string f = filePart(path);
    import std.string : lastIndexOf;
    auto idx = f.lastIndexOf('.');
    if (idx == -1 || idx == 0) return "";
    return f[idx .. $];
}

/// Extract a component from a path by AutoVarComponent.
/// This is used for the $(@D), $(@F), $(<D), $(<F), etc. variants.
///
/// Params:
///   path = the resolved automatic variable value
///   comp = which component to extract
///
/// Returns: the extracted component string.
string extractComponent(string path, AutoVarComponent comp)
{
    final switch (comp)
    {
        case AutoVarComponent.dir:
            return dirPart(path);
        case AutoVarComponent.file:
            return filePart(path);
        case AutoVarComponent.suffix:
            return suffixPart(path);
        case AutoVarComponent.basename:
            return basePart(path);
    }
}

// ---------------------------------------------------------------------------
// Unittests
// ---------------------------------------------------------------------------

unittest
{
    // --- getAutomaticVar ---

    // target
    assert(getAutomaticVar(AutomaticVar.target, "foo.o", []) == "foo.o");

    // firstPrereq
    assert(getAutomaticVar(AutomaticVar.firstPrereq, "t", []) == "");
    assert(getAutomaticVar(AutomaticVar.firstPrereq, "t", ["a.c"]) == "a.c");
    assert(getAutomaticVar(AutomaticVar.firstPrereq, "t", ["a.c", "b.c"]) == "a.c");

    // allPrereqs ($^) — deduplicated
    assert(getAutomaticVar(AutomaticVar.allPrereqs, "t", ["a.c", "b.c", "a.c"]) == "a.c b.c");
    assert(getAutomaticVar(AutomaticVar.allPrereqs, "t", []) == "");

    // allPrereqsPlus ($+) — duplicates preserved
    assert(getAutomaticVar(AutomaticVar.allPrereqsPlus, "t", ["a.c", "b.c", "a.c"]) == "a.c b.c a.c");
    assert(getAutomaticVar(AutomaticVar.allPrereqsPlus, "t", []) == "");

    // stem
    assert(getAutomaticVar(AutomaticVar.stem, "t", [], "") == "");
    assert(getAutomaticVar(AutomaticVar.stem, "t", [], "build/foo") == "build/foo");

    // newerPrereqs
    assert(getAutomaticVar(AutomaticVar.newerPrereqs, "t", ["a.c", "b.c"]) == "a.c b.c");
    assert(getAutomaticVar(AutomaticVar.newerPrereqs, "t", []) == "");

    // archiveMember (stub)
    assert(getAutomaticVar(AutomaticVar.archiveMember, "t", []) == "");

    // orderOnlyPrereqs (stub)
    assert(getAutomaticVar(AutomaticVar.orderOnlyPrereqs, "t", []) == "");
}

unittest
{
    // --- Component extraction helpers ---

    // dirPart
    assert(dirPart("src/sub/file.o") == "src/sub/");
    assert(dirPart("file.o") == "./");
    assert(dirPart("/absolute/path/file") == "/absolute/path/");
    assert(dirPart("") == "./");  // edge: empty path

    // filePart
    assert(filePart("src/sub/file.o") == "file.o");
    assert(filePart("file.o") == "file.o");
    assert(filePart("/a/b/c") == "c");
    assert(filePart("") == "");   // edge: empty path

    // basePart
    assert(basePart("src/sub/file.o") == "file");
    assert(basePart("file.o") == "file");
    assert(basePart("file") == "file");
    assert(basePart(".hidden") == ".hidden");   // dotfiles: no suffix
    assert(basePart("src/sub/file") == "file");

    // suffixPart
    assert(suffixPart("src/sub/file.o") == ".o");
    assert(suffixPart("file.o") == ".o");
    assert(suffixPart("file") == "");
    assert(suffixPart(".hidden") == "");        // dotfiles: not a suffix
    assert(suffixPart("src/sub/file") == "");
}

unittest
{
    // --- extractComponent ---

    string p = "src/sub/file.o";
    assert(extractComponent(p, AutoVarComponent.dir) == "src/sub/");
    assert(extractComponent(p, AutoVarComponent.file) == "file.o");
    assert(extractComponent(p, AutoVarComponent.suffix) == ".o");
    assert(extractComponent(p, AutoVarComponent.basename) == "file");

    // dotfile edge: ".hidden" treated as basename with no suffix
    p = ".hidden";
    assert(extractComponent(p, AutoVarComponent.dir) == "./");
    assert(extractComponent(p, AutoVarComponent.file) == ".hidden");
    assert(extractComponent(p, AutoVarComponent.suffix) == "");
    assert(extractComponent(p, AutoVarComponent.basename) == ".hidden");

    // no-suffix path
    p = "justdir/";
    // note: trailing slash means filePart is "" after stripping
    assert(extractComponent(p, AutoVarComponent.file) == "");
    assert(extractComponent(p, AutoVarComponent.suffix) == "");
    assert(extractComponent(p, AutoVarComponent.basename) == "");

    // component extraction on automatic vars: $(@D) where target is dir/file.o
    string target = "build/foo.o";
    assert(extractComponent(target, AutoVarComponent.dir) == "build/");
    assert(extractComponent(target, AutoVarComponent.file) == "foo.o");
    assert(extractComponent(target, AutoVarComponent.basename) == "foo");
    assert(extractComponent(target, AutoVarComponent.suffix) == ".o");
}
