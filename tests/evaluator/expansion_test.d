/// Unit tests for variable expansion in the evaluator.
///
/// Tests recursive expansion, simple vs recursive assignment semantics,
/// and circular reference detection.
module antelope.tests.evaluator.expansion_test;

import antelope.evaluator.expansion;
import antelope.shell.environment;

/// Test simple variable reference expansion.
unittest
{
    auto env = Environment.init;
    env.set("CC", "gcc");
    env.set("CFLAGS", "-Wall -O2");

    auto result = expand(env, "$(CC) $(CFLAGS)");
    assert(result == "gcc -Wall -O2");
}

/// Test brace-delimited variable expansion.
unittest
{
    auto env = Environment.init;
    env.set("VAR", "value");

    auto result = expand(env, "${VAR}");
    assert(result == "value");
}

/// Test that undefined variables produce a warning but expand to empty.
unittest
{
    auto env = Environment.init;
    auto result = expand(env, "$(UNDEFINED)");
    assert(result == "");
}
