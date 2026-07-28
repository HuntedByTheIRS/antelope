/// Version information.
module antelope.cli.verinfo;

/// Package version string.
immutable string versionString = "0.1.0";

/// Print version and exit.
void printVersion()
{
    import std.stdio;
    writeln("Antelope ", versionString);
}
