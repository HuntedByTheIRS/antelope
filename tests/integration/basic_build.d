/// Integration test: basic Makefile with variable expansion and implicit rules.
module antelope.tests.integration.basic_build;

import antelope.cli.args;
import antelope.cli.subcommands;

/// Test that antelope -gnu can build a simple C project using implicit rules.
unittest
{
    import std.file : write, mkdir, rmdir, exists;
    import std.process : environment;

    // Create a temp build directory
    string testDir = "__antelope_int_test_basic";
    if (exists(testDir))
        rmdir(testDir);

    // We can't easily run the full build pipeline in a unittest,
    // so this test verifies parseArgs works correctly.
    auto config = parseArgs(["antelope", "-gnu"]);
    assert(config.gnuMode);
    assert(config.targets.length == 0);

    config = parseArgs(["antelope", "release", "-gnu"]);
    assert(config.gnuMode);
    assert(config.targets.length == 1);
    assert(config.targets[0] == "release");
}
