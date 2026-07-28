/// Known GNU Make behavioral quirks and edge cases that Antelope must replicate.
///
/// GNU Make has accumulated decades of subtle behaviors that existing
/// Makefiles may depend on. This module catalogs them so Antelope can
/// emulate them when compatibility mode is active.
module antelope.compatibility.quirks;

/// A single GNU Make quirk Antelope can emulate.
struct GnuQuirk
{
    string name;
    string description;
    uint introducedVersion;
    bool enabledByDefault;
}

/// All known GNU Make quirks.
GnuQuirk[] knownQuirks()
{
    return [
        GnuQuirk("Suspended line continuation in comments",
                 "Backslash-newline inside comments still joins lines.",
                 0, true),
        GnuQuirk("Unescaped # in recipe lines",
                 "A # in a recipe line starts a comment, but only after expansion.",
                 0, true),
        GnuQuirk("Variable assignment with trailing semicolon",
                 "foo=bar; is silently accepted as assignment.", 0, true),
        GnuQuirk("Empty prerequisite list with pipe",
                 "target: | with no regular prereqs is allowed.", 0, true),
        GnuQuirk("Automatic variable propagation",
                 "$(@D) and $(@F) work even when $@ is empty.", 0, true),
        GnuQuirk("Recursive variable assignment on command line",
                 "Command-line overrides apply recursively.", 0, true),
        GnuQuirk("Secondary expansion of .EXTRA_PREREQS",
                 ".EXTRA_PREREQS undergoes secondary expansion.", 0, true),

        GnuQuirk("Backslash-newline in variable values",
                 "A backslash followed by a newline inside a variable value is "
                 ~ "consumed, joining the lines into one.",
                 0, true),
        GnuQuirk("Trailing whitespace in = assignments",
                 "In a recursive variable assignment, trailing whitespace after "
                 ~ "the value is preserved verbatim.",
                 0, true),
        GnuQuirk("Empty recipe lines",
                 "A recipe line consisting of only a tab is a valid no-op.",
                 0, true),
        GnuQuirk("Double-colon rules",
                 "A double-colon rule (target:: prereqs) allows multiple "
                 ~ "independent recipes for the same target.",
                 0, true),
        GnuQuirk("Pattern rule matching order",
                 "Match pattern rules in declaration order; the first matching "
                 ~ "rule wins, including built-in rules.",
                 0, true),
        GnuQuirk("MAKEFLAGS propagation",
                 "MAKEFLAGS contains condensed flag letters (e.g. 'n', 'd') "
                 ~ "and is automatically passed to sub-make invocations.",
                 0, true),
        GnuQuirk("export/unexport timing",
                 "The export directive takes effect immediately at parse time, "
                 ~ "not deferred to recipe execution time.",
                 0, true),
        GnuQuirk("Comment inside variable value after expansion",
                 "When a variable expands to a value containing #, that # "
                 ~ "starts a comment in recipe context.",
                 0, true),
        GnuQuirk("Nested include handling",
                 "Files included via include can themselves contain include "
                 ~ "directives, recursively.",
                 0, true),
        GnuQuirk("Target-specific variable override order",
                 "Override precedence: command-line > target-specific > "
                 ~ "pattern-specific > global variable.",
                 0, true),
        GnuQuirk(".ONESHELL behavior",
                 "With .ONESHELL, all recipe lines for a rule run in a single "
                 ~ "shell invocation, not one per line.",
                 400, true),
        GnuQuirk("Archive member syntax with ()",
                 "Archive members are referenced as libfoo.a(member.o) and "
                 ~ "support implicit rules for extraction.",
                 0, true),
        GnuQuirk("Automatic variables in prerequisite lists with .SECONDEXPANSION",
                 "Under secondary expansion, automatic variables ($@, $<, etc.) "
                 ~ "are available in prerequisite lists.",
                 381, true),
    ];
}
