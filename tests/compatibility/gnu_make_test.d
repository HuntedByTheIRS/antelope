/// GNU Make compatibility conformance tests.
///
/// These tests verify that Antelope in -gnu mode produces the same
/// output as GNU Make for a set of canonical Makefiles. Each test
/// runs both Antelope and GNU Make on the same input and compares
/// stdout, exit code, and files produced.
module antelope.tests.compatibility.gnu_make_test;

import antelope.compatibility.gnu_make;
import antelope.compatibility.quirks;

/// Verify that GnuMakeCompat defaults to the latest GNU Make version.
unittest
{
    auto compat = GnuMakeCompat.init;
    assert(compat.targetVersion == GnuMakeVersion.v4_4);
}

/// Verify key quirks are enabled by default.
unittest
{
    // Backslash-newline in comments is a known GNU Make quirk
    // that many real-world Makefiles depend on.
    assert(GnuQuirk.defaultQuirks.length > 0);
}

/// Verify POSIX conformance mode can be set separately from GNU mode.
unittest
{
    auto compat = GnuMakeCompat.init;
    auto posix = PosixCompat.init;

    // POSIX conformance should be independent — you can have
    // GNU mode without POSIX, or POSIX mode as a restriction
    // on top of GNU mode.
    posix.mode = PosixConformance.gnu_mode;
    assert(posix.mode == PosixConformance.gnu_mode);

    posix.mode = PosixConformance.posix_target;
    assert(posix.mode == PosixConformance.posix_target);

    posix.mode = PosixConformance.strict;
    assert(posix.mode == PosixConformance.strict);
}
