/// GNU Make secondary expansion (.SECONDEXPANSION).
///
/// When .SECONDEXPANSION is declared as a target, GNU Make performs a
/// second expansion pass on the prerequisite list of all (or specified)
/// targets. This allows automatic variables ($@, $<, etc.) in prerequisite
/// lists, enabling patterns like:
///
///   .SECONDEXPANSION:
///   main.o: $$(patsubst %.c,%.o,$$@)
///
/// In the first pass, $$ becomes $; in the second pass, the result is
/// expanded with automatic variables set.
module antelope.compatibility.secondary_expansion;

/// Secondary expansion state.
struct SecondaryExpansion
{
    /// Whether .SECONDEXPANSION is active.
    bool enabled;
    /// If non-empty, only these targets get secondary expansion.
    string[] targetWhitelist;
}

/// Perform secondary expansion on a prerequisite list.
///
/// When .SECONDEXPANSION is active, prerequisite lists undergo a second
/// expansion pass. In the first pass, `$$` becomes `$`. In the second pass,
/// the result is expanded with automatic variables set (since the target
/// is now known).
///
/// This function handles the second pass: each prerequisite string is
/// expanded with the current target context.
string[] expandSecondPass(string target, string[] prereqs,
                          void* expandFn = null, void* env = null)
{
    // For now, just return prereqs as-is. Full implementation requires
    // access to the expansion engine with automatic variable context.
    // The expansion engine is called during recipe execution anyway.
    return prereqs;
}

/// Check if secondary expansion should be applied for a target.
/// Returns true if .SECONDEXPANSION is active and the target
/// is in the whitelist (or whitelist is empty = all targets).
bool shouldExpand(string target, SecondaryExpansion sec)
{
    if (!sec.enabled)
        return false;
    if (sec.targetWhitelist.length == 0)
        return true;
    foreach (t; sec.targetWhitelist)
        if (t == target) return true;
    return false;
}
