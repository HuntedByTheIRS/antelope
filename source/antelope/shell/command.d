/// Shell command parsing and escaping.
module antelope.shell.command;

import std.algorithm;
import std.array;
import std.ascii;

/// A single shell command parsed from a recipe line.
struct ShellCommand
{
    string program;
    string[] arguments;
    bool ignoreErrors;   /// `-` prefix — continue on non-zero exit
    bool silent;         /// `@` prefix — don't echo the command
    bool alwaysExecute;  /// `+` prefix — execute even with -n dry run
}

// --- Private helpers ---

/// Strip consecutive `@`, `-`, `+` prefixes from the start of `line`,
/// returning the remaining line and the three flag values.
private struct PrefixResult
{
    bool silent;
    bool ignoreErrors;
    bool alwaysExecute;
    string rest;
}

private PrefixResult stripPrefixes(string line)
{
    PrefixResult result;
    result.rest = line;

    // Consume prefix characters until a non-prefix appears.
    // Example: "@-echo" → silent, ignoreErrors; rest = "echo"
    bool consumed;
    do
    {
        consumed = false;
        if (result.rest.length > 0)
        {
            switch (result.rest[0])
            {
                case '@':
                    result.silent = true;
                    result.rest = result.rest[1 .. $];
                    consumed = true;
                    break;
                case '-':
                    result.ignoreErrors = true;
                    result.rest = result.rest[1 .. $];
                    consumed = true;
                    break;
                case '+':
                    result.alwaysExecute = true;
                    result.rest = result.rest[1 .. $];
                    consumed = true;
                    break;
                default:
                    break;
            }
        }
    }
    while (consumed);

    return result;
}

/// Split the rest of a (prefix-stripped) recipe line into tokens
/// respecting single-quote, double-quote, and backslash escapes.
private string[] tokenize(string line)
{
    string[] tokens;

    size_t i = 0;
    while (i < line.length)
    {
        // Skip whitespace between tokens.
        if (isWhite(line[i]))
        {
            ++i;
            continue;
        }

        // Parse one token.
        char[] buf;
        inToken: while (i < line.length && !isWhite(line[i]))
        {
            switch (line[i])
            {
                case '"':
                    // Double-quoted segment — honour backslash escapes.
                    ++i; // skip opening quote
                    while (i < line.length && line[i] != '"')
                    {
                        if (line[i] == '\\' && i + 1 < line.length)
                        {
                            ++i; // skip backslash, take next char literally
                            buf ~= line[i];
                            ++i;
                        }
                        else
                        {
                            buf ~= line[i];
                            ++i;
                        }
                    }
                    if (i < line.length)
                        ++i; // skip closing quote
                    break;

                case '\'':
                    // Single-quoted segment — everything literal, no escapes.
                    ++i; // skip opening quote
                    while (i < line.length && line[i] != '\'')
                    {
                        buf ~= line[i];
                        ++i;
                    }
                    if (i < line.length)
                        ++i; // skip closing quote
                    break;

                case '\\':
                    // Unquoted backslash — escape next character.
                    ++i; // skip backslash
                    if (i < line.length)
                    {
                        buf ~= line[i];
                        ++i;
                    }
                    break;

                default:
                    buf ~= line[i];
                    ++i;
                    break;
            }
        }

        if (buf.length > 0)
            tokens ~= buf.idup;
    }

    return tokens;
}

/// Parse a recipe line into a ShellCommand.
///
/// GNU Make applies three optional prefix characters to recipe lines:
/// $(UL @)  = silent  — don't echo the command before execution
/// $(UL -)  = ignoreErrors — continue the build even when this command fails
/// $(UL +)  = alwaysExecute — run even in dry-run (-n) mode
///
/// Multiple prefixes may be combined (e.g. `@-echo` makes the command
/// both silent and error-tolerant).
///
/// After stripping prefixes the remaining string is split into a program
/// name and arguments.  Splitting respects shell-style quoting so that
/// `"hello world"` is preserved as a single argument.
///
/// Params:
///   line = raw recipe line (may include leading/trailing whitespace)
///
/// Returns:
///   A ShellCommand with prefix flags set and the command split into
///   program + arguments.  An empty or whitespace-only line returns a
///   default-initialised ShellCommand.
ShellCommand parseCommand(string line)
{
    // Strip surrounding whitespace first.
    auto trimmed = line.strip!isWhite;

    // Empty line → all defaults.
    if (trimmed.length == 0)
        return ShellCommand();

    // Consume optional prefixes.
    auto pref = stripPrefixes(trimmed);

    // Tokenise the remainder.
    auto tokens = tokenize(pref.rest);

    ShellCommand cmd;
    cmd.silent = pref.silent;
    cmd.ignoreErrors = pref.ignoreErrors;
    cmd.alwaysExecute = pref.alwaysExecute;

    if (tokens.length > 0)
        cmd.program = tokens[0];
    cmd.arguments = tokens.length > 1 ? tokens[1 .. $] : [];

    return cmd;
}

// --- Unittests ---

unittest
{
    // Basic: no prefixes.
    {
        auto cmd = parseCommand("gcc -o out main.c");
        assert(!cmd.silent);
        assert(!cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
        assert(cmd.program == "gcc");
        assert(cmd.arguments == ["-o", "out", "main.c"]);
    }

    // Silent prefix.
    {
        auto cmd = parseCommand("@echo hello");
        assert(cmd.silent);
        assert(!cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello"]);
    }

    // Ignore-errors prefix.
    {
        auto cmd = parseCommand("-rm -rf foo");
        assert(!cmd.silent);
        assert(cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
        assert(cmd.program == "rm");
        assert(cmd.arguments == ["-rf", "foo"]);
    }

    // Always-execute prefix.
    {
        auto cmd = parseCommand("+make sub");
        assert(!cmd.silent);
        assert(!cmd.ignoreErrors);
        assert(cmd.alwaysExecute);
        assert(cmd.program == "make");
        assert(cmd.arguments == ["sub"]);
    }

    // Multiple prefixes: @-echo → silent + ignoreErrors.
    {
        auto cmd = parseCommand("@-echo hello");
        assert(cmd.silent);
        assert(cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello"]);
    }

    // Multiple prefixes in different order: -@echo.
    {
        auto cmd = parseCommand("-@echo hello");
        assert(cmd.silent);
        assert(cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello"]);
    }

    // All three prefixes.
    {
        auto cmd = parseCommand("@-+make all");
        assert(cmd.silent);
        assert(cmd.ignoreErrors);
        assert(cmd.alwaysExecute);
        assert(cmd.program == "make");
        assert(cmd.arguments == ["all"]);
    }

    // Double-quoted argument.
    {
        auto cmd = parseCommand(`echo "hello world"`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello world"]);
    }

    // Single-quoted argument.
    {
        auto cmd = parseCommand(`echo 'hello world'`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello world"]);
    }

    // Backslash escape within double quotes.
    {
        auto cmd = parseCommand(`echo "hello \"world\""`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == [`hello "world"`]);
    }

    // Backslash escape within double quotes — backslash itself.
    {
        auto cmd = parseCommand(`echo "a\\b"`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == [`a\b`]);
    }

    // Empty string.
    {
        auto cmd = parseCommand("");
        assert(cmd.program == "");
        assert(cmd.arguments == []);
        assert(!cmd.silent);
        assert(!cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
    }

    // Whitespace only.
    {
        auto cmd = parseCommand("   \t  ");
        assert(cmd.program == "");
        assert(cmd.arguments == []);
        assert(!cmd.silent);
        assert(!cmd.ignoreErrors);
        assert(!cmd.alwaysExecute);
    }

    // Leading/trailing whitespace with prefix.
    {
        auto cmd = parseCommand("  @echo hello  ");
        assert(cmd.silent);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello"]);
    }

    // Unquoted backslash escape.
    {
        auto cmd = parseCommand(`echo hello\ world`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["hello world"]);
    }

    // Mixed quotes in separate arguments.
    {
        auto cmd = parseCommand(`echo "arg one" 'arg two'`);
        assert(cmd.program == "echo");
        assert(cmd.arguments == ["arg one", "arg two"]);
    }
}
