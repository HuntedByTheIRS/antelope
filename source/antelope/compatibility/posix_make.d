/// GNU Make's POSIX conformance mode (.POSIX target, -P flag).
///
/// GNU Make can run in POSIX-compatible mode, which disables certain GNU
/// extensions to conform to POSIX.1-2024. This module tracks which features
/// are affected and manages the conformance flags.
module antelope.compatibility.posix_make;

/// POSIX conformance level in GNU Make.
enum PosixConformance
{
    /// Default GNU Make behavior — full extensions enabled.
    gnu_mode,
    /// .POSIX target declared — disable conflicting extensions.
    posix_target,
    /// -P / --posix flag — strict POSIX mode.
    strict,
}

/// GNU Make features affected by POSIX conformance mode.
enum PosixAffectedFeature
{
    /// $(shell ...) error handling differs.
    shellErrorHandling,
    /// The $$@ variable works differently in prerequisites.
    automaticVarInPrereqs,
    /// Order of pattern rule matching differs.
    patternRuleOrder,
    /// Archive member syntax behaviour.
    archiveMembers,
}

/// Track which features are restricted in the current conformance mode.
struct PosixCompat
{
    PosixConformance mode = PosixConformance.gnu_mode;
    PosixAffectedFeature[] restrictedFeatures;
}
