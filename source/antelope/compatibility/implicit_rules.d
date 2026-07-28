/// GNU Make's built-in implicit rule database (suffix rules + pattern rules).
///
/// GNU Make ships a large set of built-in rules for common file transformations
/// (.c → .o, .c → .exe, etc.), defined as suffix rules and pattern rules.
/// This module reproduces that database and provides the matching algorithm.
module antelope.compatibility.implicit_rules;

import std.string : indexOf;

/// A single built-in implicit rule.
struct ImplicitRule
{
    string description;
    string[2] suffixes;     /// For suffix rules: .c → .o
    string targetPattern;   /// For pattern rules: %.o
    string prereqPattern;   /// For pattern rules: %.c
    string[] recipe;
    bool doubleSuffix;      /// true = .c.o:, false = %.o: %.c
}

/// Return the full set of GNU Make built-in rules.
ImplicitRule[] builtinRules()
{
    return [
        // --- C Compilation ---
        ImplicitRule("Compile C source to object file",
                     ["", ""], "%.o", "%.c",
                     ["$(CC) $(DEFS) $(DEFAULT_INCLUDES) $(INCLUDES) $(AM_CPPFLAGS) $(CPPFLAGS) $(AM_CFLAGS) $(CFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile C++ source (.cc) to object file",
                     ["", ""], "%.o", "%.cc",
                     ["$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile C++ source (.cpp) to object file",
                     ["", ""], "%.o", "%.cpp",
                     ["$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile C++ source (.C) to object file",
                     ["", ""], "%.o", "%.C",
                     ["$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile C++ source (.cxx) to object file",
                     ["", ""], "%.o", "%.cxx",
                     ["$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@"], false),

        // --- Assembly ---
        ImplicitRule("Assemble source to object file",
                     ["", ""], "%.o", "%.s",
                     ["$(AS) $(ASFLAGS) $< -o $@"], false),
        ImplicitRule("Compile preprocessed assembly to object file",
                     ["", ""], "%.o", "%.S",
                     ["$(CC) $(CPPFLAGS) -c $< -o $@"], false),

        // --- Fortran ---
        ImplicitRule("Compile Fortran (.f) to object file",
                     ["", ""], "%.o", "%.f",
                     ["$(FC) $(FFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile Fortran (.F) with preprocessing to object file",
                     ["", ""], "%.o", "%.F",
                     ["$(FC) $(FFLAGS) $(CPPFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile Fortran 90 (.f90) to object file",
                     ["", ""], "%.o", "%.f90",
                     ["$(FC) $(FFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile Fortran 95 (.f95) to object file",
                     ["", ""], "%.o", "%.f95",
                     ["$(FC) $(FFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile Fortran (.for) to object file",
                     ["", ""], "%.o", "%.for",
                     ["$(FC) $(FFLAGS) -c $< -o $@"], false),

        // --- Modula-2, Pascal, Ratfor ---
        ImplicitRule("Compile Modula-2 to object file",
                     ["", ""], "%.o", "%.mod",
                     ["$(M2C) $(M2FLAGS) $< -o $@"], false),
        ImplicitRule("Compile Pascal to object file",
                     ["", ""], "%.o", "%.p",
                     ["$(PC) $(PFLAGS) -c $< -o $@"], false),
        ImplicitRule("Compile Ratfor to object file",
                     ["", ""], "%.o", "%.r",
                     ["$(FC) $(FFLAGS) $(RFLAGS) -c $< -o $@"], false),

        // --- Lex / Yacc ---
        ImplicitRule("Generate C source with Lex",
                     ["", ""], "%.c", "%.l",
                     ["$(LEX) $(LFLAGS) -t $< > $@"], false),
        ImplicitRule("Generate C source with Yacc",
                     ["", ""], "%.c", "%.y",
                     ["$(YACC) $(YFLAGS) $< && mv y.tab.c $@"], false),
        ImplicitRule("Generate C header with Yacc",
                     ["", ""], "%.h", "%.y",
                     ["$(YACC) $(YFLAGS) -d $< && mv y.tab.h $@"], false),

        // --- Linker (C and C++) ---
        ImplicitRule("Link C object file into executable",
                     ["", ""], "%", "%.o",
                     ["$(CC) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),
        ImplicitRule("Link C++ object (.cc) into executable",
                     ["", ""], "%", "%.cc",
                     ["$(CXX) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),
        ImplicitRule("Link C++ object (.cpp) into executable",
                     ["", ""], "%", "%.cpp",
                     ["$(CXX) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),
        ImplicitRule("Link C++ object (.C) into executable",
                     ["", ""], "%", "%.C",
                     ["$(CXX) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),
        ImplicitRule("Link Fortran object (.f) into executable",
                     ["", ""], "%", "%.f",
                     ["$(FC) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),
        ImplicitRule("Link Fortran object (.f90) into executable",
                     ["", ""], "%", "%.f90",
                     ["$(FC) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) -o $@"], false),

        // --- Preprocessing and assembly generation ---
        ImplicitRule("Preprocess C source to output file",
                     ["", ""], "%.i", "%.c",
                     ["$(CC) $(CPPFLAGS) -E $< -o $@"], false),
        ImplicitRule("Generate assembly from C source",
                     ["", ""], "%.s", "%.c",
                     ["$(CC) $(CPPFLAGS) $(CFLAGS) -S $< -o $@"], false),
        ImplicitRule("Preprocess assembly source",
                     ["", ""], "%.s", "%.S",
                     ["$(CPP) $(CPPFLAGS) $< -o $@"], false),

        // --- Texinfo / TeX ---
        ImplicitRule("Generate DVI from Texinfo source",
                     ["", ""], "%.dvi", "%.texinfo",
                     ["$(TEXI2DVI) $(TEXI2DVI_FLAGS) $<"], false),
        ImplicitRule("Generate DVI from TeX source",
                     ["", ""], "%.dvi", "%.tex",
                     ["$(TEX) $<"], false),

        // --- CWEB ---
        ImplicitRule("Generate C source from CWEB",
                     ["", ""], "%.c", "%.w",
                     ["$(CTANGLE) $< -o $@"], false),
        ImplicitRule("Generate TeX source from CWEB",
                     ["", ""], "%.tex", "%.w",
                     ["$(CWEAVE) $< -o $@"], false),

        // --- SCCS ---
        ImplicitRule("Get source file from SCCS",
                     ["", ""], "%", "s.%",
                     ["$(GET) $(GFLAGS) $<"], false),
        ImplicitRule("Get source file from SCCS subdirectory",
                     ["", ""], "%", "SCCS/s.%",
                     ["$(GET) $(GFLAGS) $<"], false),

        // --- Archive ---
        ImplicitRule("Update archive from object file",
                     ["", ""], "%.a", "%.o",
                     ["$(AR) $(ARFLAGS) $@ $^"], false),

        // --- Suffix rules (legacy equivalents) ---
        ImplicitRule("Suffix rule: .c to .o",
                     ["c", "o"], "", "",
                     ["$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@"], true),
        ImplicitRule("Suffix rule: .cc to .o",
                     ["cc", "o"], "", "",
                     ["$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@"], true),
        ImplicitRule("Suffix rule: .f to .o",
                     ["f", "o"], "", "",
                     ["$(FC) $(FFLAGS) -c $< -o $@"], true),
        ImplicitRule("Suffix rule: .s to .o",
                     ["s", "o"], "", "",
                     ["$(AS) $(ASFLAGS) $< -o $@"], true),
        ImplicitRule("Suffix rule: .y to .c",
                     ["y", "c"], "", "",
                     ["$(YACC) $(YFLAGS) $< && mv y.tab.c $@"], true),
        ImplicitRule("Suffix rule: .l to .c",
                     ["l", "c"], "", "",
                     ["$(LEX) $(LFLAGS) -t $< > $@"], true),
    ];
}

/// Result of a successful implicit rule match.
struct ImplicitMatch
{
    ImplicitRule rule;
    string stem;
    string resolvedTarget;
    string resolvedPrereq;
}

/// Try to match an implicit rule for the given target.
///
/// Iterates built-in rules in order, trying each pattern against the target.
/// The first matching pattern rule wins (matching GNU Make semantics).
/// Returns null if no rule matches.
ImplicitMatch* matchImplicitRule(string target)
{
    auto rules = builtinRules();

    foreach (ref rule; rules)
    {
        string pattern = rule.targetPattern;
        if (pattern.length == 0)
            continue;

        // Split pattern on '%' — must have exactly one '%' (or two for edge cases)
        size_t pct = pattern.indexOf('%');
        if (pct == size_t.max)
        {
            // No wildcard — exact match
            if (target == pattern)
                return createMatch(rule, target, "", "");
            continue;
        }

        string prefix = pattern[0 .. pct];
        string suffix = pattern[pct + 1 .. $];

        // Target must start with prefix and end with suffix
        if (target.length < prefix.length + suffix.length)
            continue;
        if (target[0 .. prefix.length] != prefix)
            continue;
        if (target[target.length - suffix.length .. $] != suffix)
            continue;

        // Extract the stem (the part matching %)
        string stem = target[prefix.length .. target.length - suffix.length];

        // Resolve prerequisite by substituting stem into prereqPattern
        string prereqPattern = rule.prereqPattern;
        string resolvedPrereq = substitutePercent(prereqPattern, stem);

        return createMatch(rule, target, stem, resolvedPrereq);
    }

    return null;
}

private ImplicitMatch* createMatch(ImplicitRule rule, string target, string stem, string resolvedPrereq)
{
    auto match = new ImplicitMatch();
    match.rule = rule;
    match.stem = stem;
    match.resolvedTarget = target;
    match.resolvedPrereq = resolvedPrereq;
    return match;
}

/// Substitute the first '%' in pattern with replacement.
private string substitutePercent(string pattern, string replacement)
{
    size_t pct = pattern.indexOf('%');
    if (pct == size_t.max)
        return pattern;
    return pattern[0 .. pct] ~ replacement ~ pattern[pct + 1 .. $];
}

/// Convenience: get the recipe lines from a match result.
string[] recipeLines(ImplicitMatch* match)
{
    if (match is null)
        return null;
    return match.rule.recipe;
}
