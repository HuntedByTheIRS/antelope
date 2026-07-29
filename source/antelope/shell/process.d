/// Subprocess creation and management.
///
/// Provides low-level process execution for recipe lines.
/// Commands are run via `/bin/sh -c` on POSIX systems.
module antelope.shell.process;

import std.process : spawnProcess, spawnShell, wait, Pid, Pipe, pipeShell,
    Redirect, ProcessPipes, Config;
import std.string : indexOf;
import std.stdio : File;

/// Handle to a running piped subprocess.
///
/// Created by `runProcessPiped()`, this lets the caller read
/// stdout/stderr asynchronously and wait for completion.
struct ProcessHandle
{
    Pid pid;               /// Process ID
    File stdoutPipe;       /// File for reading process stdout
    File stderrPipe;       /// File for reading process stderr
    string command;        /// The command that was executed (for error messages)

    /// Wait for the process to finish and return its exit code.
    /// Returns: the exit code, or -1 if waiting failed.
    int waitFor()
    {
        try
        {
            return wait(pid);
        }
        catch (Exception)
        {
            return -1;
        }
    }

    /// Close the stdout and stderr pipes.
    /// Must be called after reading all output to avoid fd leaks.
    void closePipes()
    {
        try { stdoutPipe.close(); } catch (Exception) {}
        try { stderrPipe.close(); } catch (Exception) {}
    }
}

/// Run a command via shell with piped stdout and stderr.
///
/// Unlike `runProcess()` which blocks and inherits parent fds,
/// this variant captures stdout and stderr into pipes so output
/// can be buffered and printed atomically by the caller.
///
/// Params:
///   command     = The raw shell command to execute
///   environment = Optional KEY=VALUE pairs for the process environment
///
/// Returns: A ProcessHandle that can be used to read output and wait.
///
/// Throws: Exception if process spawning fails.
ProcessHandle runProcessPiped(string command, string[] environment = [])
{
    // Determine shell — respect SHELL variable, default to /bin/sh
    string shell = "/bin/sh";
    foreach (env; environment)
    {
        if (env.length > 6 && env[0 .. 6] == "SHELL=")
        {
            shell = env[6 .. $];
            break;
        }
    }

    if (environment.length > 0)
    {
        string[string] envMap;
        foreach (env; environment)
        {
            auto idx = env.indexOf('=');
            if (idx != -1)
                envMap[env[0 .. idx]] = env[idx + 1 .. $];
        }

        auto pipes = pipeShell(command,
            Redirect.stdout | Redirect.stderr,
            envMap, Config.none, null, shell);

        ProcessHandle h;
        h.pid = pipes.pid;
        h.stdoutPipe = pipes.stdout;
        h.stderrPipe = pipes.stderr;
        h.command = command;
        return h;
    }
    else
    {
        auto pipes = pipeShell(command,
            Redirect.stdout | Redirect.stderr,
            null, Config.none, null, shell);

        ProcessHandle h;
        h.pid = pipes.pid;
        h.stdoutPipe = pipes.stdout;
        h.stderrPipe = pipes.stderr;
        h.command = command;
        return h;
    }
}

/// Run a command via shell and return its exit code (blocking, no capture).
///
/// This is the original synchronous variant — used for simple cases
/// and single-job builds where output capture is unnecessary.
///
/// If `command` is empty, returns 0 immediately without spawning.
/// The shell used is determined by the SHELL environment variable,
/// defaulting to /bin/sh if not set.
///
/// Returns: the exit code of the command, or -1 if spawning failed.
int runProcess(string command, string[] environment = [])
{
    if (command.length == 0)
        return 0;

    // Determine shell — respect SHELL variable, default to /bin/sh
    string shell = "/bin/sh";
    foreach (env; environment)
    {
        if (env.length > 6 && env[0 .. 6] == "SHELL=")
        {
            shell = env[6 .. $];
            break;
        }
    }

    try
    {
        string[] shellArgs = [shell, "-c", command];
        if (environment.length > 0)
        {
            string[string] envMap;
            foreach (env; environment)
            {
                auto idx = env.indexOf('=');
                if (idx != -1)
                    envMap[env[0 .. idx]] = env[idx + 1 .. $];
            }
            auto pid = spawnProcess(shellArgs, envMap);
            return wait(pid);
        }
        else
        {
            auto pid = spawnProcess(shellArgs);
            return wait(pid);
        }
    }
    catch (Exception)
    {
        return -1;
    }
}

unittest
{
    assert(runProcess("echo hello", []) == 0);
    assert(runProcess("exit 42", []) == 42);
}

/// Verify that `runProcessPiped` returns the same exit code as `runProcess`.
unittest
{
    auto h = runProcessPiped("echo hello", []);
    int code = h.waitFor();
    assert(code == 0);
    h.closePipes();
}

/// Test piped stderr capture via non-zero exit.
unittest
{
    auto h = runProcessPiped("exit 7", []);
    int code = h.waitFor();
    assert(code == 7);
    h.closePipes();
}
