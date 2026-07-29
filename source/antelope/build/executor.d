/// Command execution engine — runs recipe lines and reports results.
///
/// Now supports parallel execution: `executeTarget()` spawns processes
/// with piped stdout/stderr for output buffering, while `execute()`
/// remains available for simple synchronous use.
module antelope.build.executor;

import antelope.shell.process;
import antelope.build.target;
import antelope.build.output;
import antelope.diagnostics.output;

/// Result of executing a single recipe line.
struct ExecResult
{
    bool success;    /// True if the command succeeded or ignoreErrors was set
    string output;   /// Captured stdout + stderr from the process
    int exitCode;    /// Exit code from the process
}

/// Result of executing all recipe lines for a single target.
struct JobResult
{
    string targetName;    /// Name of the target that was built
    bool success;         /// True if all recipe lines succeeded
    int exitCode;         /// Last non-zero exit code (0 if all succeeded)
    string[] stdoutLines; /// Captured stdout, one entry per recipe line
    string[] stderrLines; /// Captured stderr, one entry per recipe line
    bool hadEcho;         /// True if any non-@ recipe line was executed
}

/// Execute a command string and return the result (synchronous, no capture).
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

/// Execute all recipe lines for a single target, capturing output.
///
/// Each recipe line is expanded (via the caller-supplied expander),
/// stripped of prefix characters, printed according to echo rules,
/// and executed via a piped subprocess.  Output is buffered into the
/// supplied `OutputManager`.
///
/// The `expander` delegate is called to perform variable expansion
/// (e.g., $(CC), $@, $<) at execution time.  It receives:
///   - The raw recipe line text
///   - The target name (for $@ expansion)
///   - The target's prerequisites (for $<, $^ expansion)
///   - The target's stem (for $* expansion in pattern rules)
///
/// Params:
///   t           = The target to build
///   execEnv     = Environment variables (KEY=VALUE) for the subprocess
///   expander    = Delegate for variable expansion
///   output      = Output buffer manager (may be null for live mode)
///   isDryRun    = If true, print commands but don't execute
///   silentMode  = If true, suppress echo of non-@ lines
///
/// Returns: JobResult with success flag and captured output.
JobResult executeTarget(
    Target t,
    string[] execEnv,
    string delegate(string, string, string[], string) expander,
    OutputManager* output,
    bool isDryRun = false,
    bool silentMode = false)
{
    import std.string : stripLeft;

    JobResult result;
    result.targetName = t.name;
    result.success = true;
    result.exitCode = 0;

    // Short-circuit: targets with no recipe are always "successful"
    // (they exist on disk or are phony/intermediate markers).
    if (t.recipe.length == 0)
        return result;

    foreach (recipeLine; t.recipe)
    {
        // Expand variables in the recipe line.
        // Automatic variables ($@, $<, $^, $*, etc.) are resolved
        // against the current target context.
        string expanded = expander(recipeLine, t.name,
            t.prerequisites, t.stem);

        // Strip prefix characters to determine echo/error behaviour.
        string trimmed = expanded.stripLeft();
        bool ignoreErrors;
        bool silent = silentMode;

        if (trimmed.length > 0)
        {
            bool stripping = true;
            while (stripping && trimmed.length > 0)
            {
                stripping = false;
                switch (trimmed[0])
                {
                    case '@':
                        silent = true;
                        trimmed = trimmed[1 .. $];
                        stripping = true;
                        break;
                    case '-':
                        ignoreErrors = true;
                        trimmed = trimmed[1 .. $];
                        stripping = true;
                        break;
                    case '+':
                        trimmed = trimmed[1 .. $];
                        stripping = true;
                        break;
                    default:
                        break;
                }
            }
        }

        if (trimmed.length == 0)
            continue;

        // Echo: print the command unless suppressed.
        // GNU Make prints the expanded form.
        string echoLine = expanded.stripLeft();
        bool shouldEcho = !silent && echoLine.length > 0;

        if (shouldEcho)
        {
            if (output)
            {
                output.bufferStdout(t.name, echoLine);
                output.markEchoed(t.name);
                result.hadEcho = true;
            }
            else
            {
                log(LogLevel.normal, echoLine);
            }
        }

        // Dry run: skip execution.
        if (isDryRun)
        {
            result.stdoutLines ~= shouldEcho ? echoLine : "";
            continue;
        }

        // Execute the command with piped output.
        auto ph = runProcessPiped(trimmed, execEnv);

        // Read stdout and stderr from pipes.
        string lineStdout;
        string lineStderr;

        // Simple line-by-line reading from the pipes.
        // NOTE: stdout is read first, then stderr.  If the child process
        // fills its stderr pipe buffer (>64KB on Linux) before stdout
        // is fully drained, both sides deadlock.  For typical compiler
        // output this is unlikely; a future fix should drain both pipes
        // concurrently via select/poll or lightweight threads.
        try
        {
            import std.string : chomp;

            // Read stdout — ProcessHandle.stdoutPipe is a File directly.
            foreach (line; ph.stdoutPipe.byLine)
            {
                string s = line.chomp().idup;
                lineStdout ~= s ~ "\n";
                if (output)
                    output.bufferStdout(t.name, s);
                else
                    log(LogLevel.normal, s);
            }

            // Read stderr
            foreach (line; ph.stderrPipe.byLine)
            {
                string s = line.chomp().idup;
                lineStderr ~= s ~ "\n";
                if (output)
                    output.bufferStderr(t.name, s);
                else
                    log(LogLevel.normal, s);
            }
        }
        catch (Exception e)
        {
            // Log pipe errors but continue — the process exit code
            // will determine success/failure.
            log(LogLevel.dbg, "[" ~ t.name ~ "] pipe read error: " ~ e.msg);
        }

        // Wait for the process.
        int code = ph.waitFor();
        ph.closePipes();

        // Store output
        result.stdoutLines ~= lineStdout;
        result.stderrLines ~= lineStderr;

        // Check result
        if (code != 0 && !ignoreErrors)
        {
            result.success = false;
            result.exitCode = code;
            return result;
        }

        if (code != 0)
            result.exitCode = code;
    }

    return result;
}

///
unittest
{
    // Simple synchronous execution (no expansion needed for this test).
    auto r = execute("echo hello");
    assert(r.success);
    assert(r.exitCode == 0);
}

///
unittest
{
    // Error-tolerant execution.
    auto r = execute("-exit 1");
    assert(r.success);       // - prefix ignores errors
    assert(r.exitCode == 1);
}

///
unittest
{
    // Target execution with piped output.
    Target t;
    t.name = "test";
    t.recipe = ["echo hello world"];

    // Identity expander (no variable substitution).
    string expand(string ln, string tn, string[] pr, string st) { return ln; }

    auto result = executeTarget(t, [], &expand, null, false, false);
    assert(result.success);
    assert(result.exitCode == 0);
}

///
unittest
{
    // Target with failed recipe line.
    Target t;
    t.name = "failing";
    t.recipe = ["exit 3"];

    string expand(string ln, string tn, string[] pr, string st) { return ln; }

    auto result = executeTarget(t, [], &expand, null, false, false);
    assert(!result.success);
    assert(result.exitCode == 3);
}
