/// Command-line argument parsing.
///
/// Pattern: antelope <subcommand> <options> --[flags]
/// Subcommand defaults to `build` when omitted.
module antelope.cli.args;

import std.algorithm.searching : startsWith;
import std.conv : to;
import std.string : strip, indexOf;
import std.ascii : isDigit;

/// Available subcommands.
enum Subcommand
{
    build,      /// Run the build (default)
    hunt,       /// Makefile → Antefile converter (late-stage)
    configure,  /// Autotools configure.ac handler (future)
}

/// Parsed CLI configuration.
struct CliConfig
{
    /// Which subcommand to run.
    Subcommand subcommand = Subcommand.build;

    /// Build targets to execute.
    string[] targets;

    /// Explicit build file (--file / -f <path>).
    string file;

    /// Enable GNU Make compatibility mode (-gnu / --gnu).
    /// Enables Makefile/makefile reading, implicit rules,
    /// automatic variables, VPATH, and all GNU Make semantics.
    bool gnuMode;

    /// Dry run: show what would be done without executing (-n / --dry-run).
    bool dryRun;

    /// Debug output (-d / --debug).
    bool debugMode;

    /// POSIX conformance mode (-P / --posix).
    bool posix;

    /// Parallel job count (-j <N>). 0 = unlimited, 1 = serial (default).
    uint jobs = 1;

    /// Change to directory before execution (-C <dir>).
    string directory;

    /// Show help (--help).
    bool showHelp;

    /// Show version (--version).
    bool showVersion;

    /// Variable overrides from the command line (VAR=value style).
    /// GNU Make passes these with highest precedence.
    string[string] varOverrides;
}

// --- Helpers ---

/// Check whether a string consists entirely of digit characters.
private bool allDigits(string s)
{
    if (s.length == 0)
        return false;
    foreach (c; s)
    {
        if (!isDigit(c))
            return false;
    }
    return true;
}

/// Parse a subcommand string into the enum.
private Subcommand parseSubcommand(string s)
{
    switch (s)
    {
        case "build":
            return Subcommand.build;
        case "hunt":
            return Subcommand.hunt;
        case "configure":
            return Subcommand.configure;
        default:
            return Subcommand.build;
    }
}

/// Check whether a string names a recognized subcommand.
private bool isSubcommand(string s)
{
    return s == "build" || s == "hunt" || s == "configure";
}

// --- Public API ---

/// Parse command-line arguments into a CliConfig.
///
/// Pattern: antelope [targets...] -gnu [flags]
/// The first positional argument that matches a subcommand name
/// (build, hunt, configure) sets the subcommand.  Otherwise all
/// positionals become build targets.
///
/// Unknown flags are silently ignored (GNU Make compatibility).
CliConfig parseArgs(string[] args)
{
    CliConfig config;
    bool firstPositional = true;
    bool doneWithFlags = false;

    for (size_t i = 1; i < args.length; i++)
    {
        string arg = args[i];

        // -- stops flag parsing; everything after is a target
        if (!doneWithFlags && arg == "--")
        {
            doneWithFlags = true;
            continue;
        }

        // After --, everything is a target
        if (doneWithFlags)
        {
            config.targets ~= arg;
            continue;
        }

        // --help / --version stop immediately
        if (arg == "--help")
        {
            config.showHelp = true;
            break;
        }
        if (arg == "--version")
        {
            config.showVersion = true;
            break;
        }

        // Boolean flags
        if (arg == "-gnu" || arg == "--gnu")
        {
            config.gnuMode = true;
            continue;
        }
        if (arg == "-n" || arg == "--dry-run")
        {
            config.dryRun = true;
            continue;
        }
        if (arg == "-d" || arg == "--debug")
        {
            config.debugMode = true;
            continue;
        }
        if (arg == "-P" || arg == "--posix")
        {
            config.posix = true;
            continue;
        }

        // -jN (combined) or -j N (space-separated)
        if (arg == "-j")
        {
            if (i + 1 < args.length && allDigits(args[i + 1]))
            {
                i++;
                config.jobs = args[i].to!uint;
            }
            // else: missing/ambiguous argument → keep default jobs=1
            continue;
        }
        if (arg.startsWith("-j") && arg.length > 2)
        {
            string numPart = arg[2 .. $];
            if (allDigits(numPart))
            {
                config.jobs = numPart.to!uint;
            }
            // else: invalid number → silently ignore (keep default)
            continue;
        }

        // -f file or --file file
        if (arg == "-f" || arg == "--file")
        {
            if (i + 1 < args.length)
            {
                i++;
                config.file = args[i];
            }
            // else: missing argument → keep default empty file
            continue;
        }

        // -Cdir (combined) or -C dir (space-separated)
        if (arg == "-C")
        {
            if (i + 1 < args.length)
            {
                i++;
                config.directory = args[i];
            }
            // else: missing argument → keep default empty directory
            continue;
        }
        if (arg.startsWith("-C") && arg.length > 2)
        {
            config.directory = strip(arg[2 .. $]);
            continue;
        }

        // Subcommand detection: only the first positional is checked
        if (firstPositional)
        {
            firstPositional = false;
            if (isSubcommand(arg))
            {
                config.subcommand = parseSubcommand(arg);
                continue;
            }
        }

        // Unknown flags → silently ignore (GNU Make compatibility)
        if (arg.startsWith("-"))
        {
            continue;
        }

        // Variable override: VAR=value (GNU Make command-line var)
        auto eqPos = indexOf(arg, '=');
        if (eqPos > 0)
        {
            string varName = arg[0 .. eqPos];
            string varValue = arg[eqPos + 1 .. $];
            config.varOverrides[varName] = varValue;
            continue;
        }

        // Everything else is a target
        config.targets ~= arg;
    }

    return config;
}

// --- Unittests ---

unittest
{
    // Default: empty args
    {
        auto c = parseArgs(["antelope"]);
        assert(c.subcommand == Subcommand.build);
        assert(c.targets.length == 0);
        assert(c.jobs == 1);
        assert(!c.gnuMode);
        assert(!c.dryRun);
        assert(!c.debugMode);
        assert(!c.posix);
        assert(!c.showHelp);
        assert(!c.showVersion);
        assert(c.file.length == 0);
        assert(c.directory.length == 0);
    }

    // -gnu flag
    {
        auto c = parseArgs(["antelope", "-gnu"]);
        assert(c.gnuMode);
        assert(c.targets.length == 0);
    }
    {
        auto c = parseArgs(["antelope", "--gnu"]);
        assert(c.gnuMode);
    }

    // -gnu with targets
    {
        auto c = parseArgs(["antelope", "-gnu", "all", "clean"]);
        assert(c.gnuMode);
        assert(c.targets == ["all", "clean"]);
    }

    // Targets without -gnu
    {
        auto c = parseArgs(["antelope", "release", "-gnu"]);
        assert(c.gnuMode);
        assert(c.targets == ["release"]);
    }

    // Subcommand: build
    {
        auto c = parseArgs(["antelope", "build", "-j4"]);
        assert(c.subcommand == Subcommand.build);
        assert(c.jobs == 4);
    }
    {
        auto c = parseArgs(["antelope", "build"]);
        assert(c.subcommand == Subcommand.build);
    }

    // Subcommand: hunt
    {
        auto c = parseArgs(["antelope", "hunt"]);
        assert(c.subcommand == Subcommand.hunt);
    }

    // Subcommand: configure
    {
        auto c = parseArgs(["antelope", "configure"]);
        assert(c.subcommand == Subcommand.configure);
    }

    // -jN combined form
    {
        auto c = parseArgs(["antelope", "-j8"]);
        assert(c.jobs == 8);
    }
    {
        auto c = parseArgs(["antelope", "-j0"]);   // unlimited
        assert(c.jobs == 0);
    }

    // -j N space-separated
    {
        auto c = parseArgs(["antelope", "-j", "4"]);
        assert(c.jobs == 4);
    }

    // -j alone (missing argument) → default
    {
        auto c = parseArgs(["antelope", "-j"]);
        assert(c.jobs == 1);
    }

    // -j followed by non-numeric → default, next arg not consumed
    {
        auto c = parseArgs(["antelope", "-j", "all"]);
        assert(c.jobs == 1);
        assert(c.targets == ["all"]);
    }

    // -C dir space-separated
    {
        auto c = parseArgs(["antelope", "-C", "/tmp"]);
        assert(c.directory == "/tmp");
    }

    // -Cdir combined
    {
        auto c = parseArgs(["antelope", "-C/tmp"]);
        assert(c.directory == "/tmp");
    }

    // -C alone (missing argument) → default
    {
        auto c = parseArgs(["antelope", "-C"]);
        assert(c.directory.length == 0);
    }

    // -n / --dry-run
    {
        auto c = parseArgs(["antelope", "-n"]);
        assert(c.dryRun);
    }
    {
        auto c = parseArgs(["antelope", "--dry-run"]);
        assert(c.dryRun);
    }

    // -d / --debug
    {
        auto c = parseArgs(["antelope", "-d"]);
        assert(c.debugMode);
    }
    {
        auto c = parseArgs(["antelope", "--debug"]);
        assert(c.debugMode);
    }

    // -P / --posix
    {
        auto c = parseArgs(["antelope", "-P"]);
        assert(c.posix);
    }
    {
        auto c = parseArgs(["antelope", "--posix"]);
        assert(c.posix);
    }

    // -f file / --file file
    {
        auto c = parseArgs(["antelope", "-f", "mymakefile"]);
        assert(c.file == "mymakefile");
    }
    {
        auto c = parseArgs(["antelope", "--file", "mymakefile"]);
        assert(c.file == "mymakefile");
    }

    // -f alone (missing argument) → default
    {
        auto c = parseArgs(["antelope", "-f"]);
        assert(c.file.length == 0);
    }

    // --help stops parsing
    {
        auto c = parseArgs(["antelope", "--help", "-gnu", "target"]);
        assert(c.showHelp);
        assert(!c.gnuMode);
        assert(c.targets.length == 0);
    }

    // --version stops parsing
    {
        auto c = parseArgs(["antelope", "--version", "-gnu"]);
        assert(c.showVersion);
        assert(!c.gnuMode);
    }

    // -- separates targets from flags
    {
        auto c = parseArgs(["antelope", "--", "-gnu", "all"]);
        assert(c.targets == ["-gnu", "all"]);
        assert(!c.gnuMode);
    }

    // -- with targets before and after
    {
        auto c = parseArgs(["antelope", "a", "--", "b", "c"]);
        assert(c.targets == ["a", "b", "c"]);
    }

    // Unknown flags silently ignored
    {
        auto c = parseArgs(["antelope", "-k", "--keep-going", "target"]);
        assert(c.targets == ["target"]);
    }

    // Multiple flags combined
    {
        auto c = parseArgs(["antelope", "-gnu", "-d", "-P", "-n", "-j", "16"]);
        assert(c.gnuMode);
        assert(c.debugMode);
        assert(c.posix);
        assert(c.dryRun);
        assert(c.jobs == 16);
    }

    // Interleaved flags and positionals
    {
        auto c = parseArgs(["antelope", "-gnu", "all", "-j8", "clean"]);
        assert(c.gnuMode);
        assert(c.jobs == 8);
        assert(c.targets == ["all", "clean"]);
    }

    // Subcommand with other positionals become targets
    {
        auto c = parseArgs(["antelope", "build", "release"]);
        assert(c.subcommand == Subcommand.build);
        assert(c.targets == ["release"]);
    }

    // "build" as a target name (not first positional)
    {
        auto c = parseArgs(["antelope", "release", "build"]);
        assert(c.subcommand == Subcommand.build);  // default
        assert(c.targets == ["release", "build"]);
    }
}
