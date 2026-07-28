/// Output formatting — colored terminal output, logging levels, and verbosity.
module antelope.diagnostics.output;

import std.stdio;
import core.sys.posix.unistd : isatty;

/// Log verbosity level.
enum LogLevel
{
    quiet,
    normal,
    verbose,
    dbg,
}

/// Current global log level threshold.
/// Messages below this level are suppressed.
LogLevel currentLogLevel = LogLevel.normal;

/// Set the current log level threshold.
/// Params: level = new verbosity threshold.
void setLogLevel(LogLevel level)
{
    currentLogLevel = level;
}

/// Write a log message at the given level.
///
/// Filters by `currentLogLevel`: messages below the threshold are suppressed.
/// When stdout is a TTY, the output is colored:
///   - `normal` → bold
///   - `verbose` → plain
///   - `dbg`     → dim/grey
///
/// Params:
///   level   = severity of this message
///   message = the text to write
void log(LogLevel level, string message)
{
    // Quiet mode suppresses everything.
    if (currentLogLevel == LogLevel.quiet)
        return;

    // Suppress messages below the threshold (unless in debug mode).
    if (currentLogLevel != LogLevel.dbg && level < currentLogLevel)
        return;

    // Plain output when not a terminal.
    if (isatty(stdout.fileno) == 0)
    {
        writeln(message);
        return;
    }

    // Colored output on TTY.
    final switch (level)
    {
        case LogLevel.quiet:
            // Quiet messages are filtered above; this is unreachable.
            return;
        case LogLevel.normal:
            writefln("\x1b[1m%s\x1b[22m", message);
            break;
        case LogLevel.verbose:
            writeln(message);
            break;
        case LogLevel.dbg:
            writefln("\x1b[2m%s\x1b[22m", message);
            break;
    }
}

// --- Tests ---

unittest
{
    import std.exception : assertNotThrown;

    // Default level is normal.
    assert(currentLogLevel == LogLevel.normal);

    // setLogLevel round-trip.
    setLogLevel(LogLevel.quiet);
    assert(currentLogLevel == LogLevel.quiet);
    setLogLevel(LogLevel.normal);
    assert(currentLogLevel == LogLevel.normal);

    // All log levels can be called without throwing.
    assertNotThrown!Exception(log(LogLevel.normal, "normal test message"));
    assertNotThrown!Exception(log(LogLevel.verbose, "verbose test message"));
    assertNotThrown!Exception(log(LogLevel.dbg, "dbg test message"));

    // Quiet suppresses everything — no crash, no output.
    setLogLevel(LogLevel.quiet);
    assertNotThrown!Exception(log(LogLevel.normal, "should be suppressed"));
    assertNotThrown!Exception(log(LogLevel.dbg, "should be suppressed"));

    // Restore default for subsequent tests.
    setLogLevel(LogLevel.normal);
}
