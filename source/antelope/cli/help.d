/// Help text display.
module antelope.cli.help;

/// Print usage information.
void printHelp()
{
    import std.stdio;
    writeln("Antelope — a GNU Make replacement and superset.");
    writeln("Usage: antelope <subcommand> [options] [targets]");
    writeln();
    writeln("Subcommands:");
    writeln("  build         Run the build (default)");
    writeln("  hunt          Convert Makefile to Antefile (late-stage)");
    writeln("  configure     Autotools configure.ac replacement (future)");
    writeln();
    writeln("Flags (common):");
    writeln("  -gnu          Enable GNU Make compatibility mode");
    writeln("  -f <file>     Use <file> as the build file");
    writeln("  -j <N>        Run <N> jobs in parallel");
    writeln("  -C <dir>      Change to <dir> before executing");
    writeln("  -n            Dry run (print commands, don't execute)");
    writeln("  -d            Enable debug output");
    writeln("  -P            POSIX conformance mode");
    writeln("  --help        Show this help");
    writeln("  --version     Show version");
    writeln();
    writeln("Native mode (default): reads antefile or antelope (case-insensitive)");
    writeln("GNU mode (-gnu): reads GNUmakefile, Makefile, or makefile");
}
