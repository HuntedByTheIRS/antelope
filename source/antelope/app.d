/// Entry point for the Antelope build system.
///
/// CLI pattern: antelope <subcommand> <options> --[flags]
/// Subcommand defaults to `build` when omitted.
module antelope.app;

import std.stdio;
import antelope.cli.args;
import antelope.cli.subcommands;
import antelope.cli.help;
import antelope.cli.verinfo;

int main(string[] args)
{
    // Parse CLI arguments into config
    CliConfig config = parseArgs(args);

    // Handle help/version quickly before dispatch
    if (config.showHelp)
    {
        printHelp();
        return 0;
    }
    if (config.showVersion)
    {
        printVersion();
        return 0;
    }

    // Dispatch to the appropriate subcommand
    return dispatchSubcommand(config);
}
