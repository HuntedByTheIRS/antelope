/// Command execution engine — runs recipe lines and reports results.
module antelope.build.executor;

import antelope.shell.process;

/// Result of executing a single recipe line.
struct ExecResult
{
    bool success;    /// True if the command succeeded or ignoreErrors was set
    string output;   /// (reserved for future output capture)
    int exitCode;    /// Exit code from the process
}

/// Execute a command string and return the result.
///
/// Handles GNU Make recipe prefix characters (@, -, +), then passes the
/// remaining line directly to /bin/sh.  Tokenization is deliberately
/// avoided — the shell interprets metacharacters (;, >, <, |, &&, ||)
/// that would be broken by argument-level quoting.
///
/// Params:
///   command     = The raw recipe line text (may include prefix chars)
///   environment = Optional environment variables (KEY=VALUE) to pass to
///                 the subprocess. If empty, the parent env is inherited.
///
/// Returns: ExecResult with success flag, output, and exit code.
ExecResult execute(string command, string[] environment = [])
{
    import std.string : stripLeft;

    string trimmed = command.stripLeft();
    if (trimmed.length == 0)
        return ExecResult(true, "", 0);

    // Strip GNU Make prefix characters (@, -, +) from the start of the
    // line.  These flags affect behaviour; the rest of the line is
    // passed verbatim to the shell.
    bool ignoreErrors;

    while (true)
    {
        if (trimmed.length == 0) break;
        switch (trimmed[0])
        {
            case '@': trimmed = trimmed[1..$]; continue;
            case '-': ignoreErrors = true; trimmed = trimmed[1..$]; continue;
            case '+': trimmed = trimmed[1..$]; continue;
            default: break;
        }
        break;
    }

    if (trimmed.length == 0)
        return ExecResult(true, "", 0);

    // Execute via /bin/sh — shells handle metacharacters natively.
    int code = runProcess(trimmed, environment);

    // Success if exit code is 0 OR the ignoreErrors (-) flag is set
    bool ok = (code == 0 || ignoreErrors);
    return ExecResult(ok, "", code);
}
