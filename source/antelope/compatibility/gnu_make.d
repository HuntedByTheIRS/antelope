/// GNU Make syntax and semantics compatibility layer.
module antelope.compatibility.gnu_make;

/// Feature flags for GNU Make version targeting.
enum GnuMakeVersion
{
    v3_81,
    v4_0,
    v4_1,
    v4_2,
    v4_3,
    v4_4,
}

/// Configure which GNU Make features to emulate.
struct GnuMakeCompat
{
    GnuMakeVersion targetVersion = GnuMakeVersion.v4_4;
    bool enableSecondaryExpansion;
    bool enableGnuBuiltins;
    bool enableGnuExtensions;

    /// Returns a GnuMakeCompat configured for full GNU Make 4.4 compatibility.
    static GnuMakeCompat withDefaults()
    {
        return GnuMakeCompat(GnuMakeVersion.v4_4, true, true, true);
    }
}
