/// Subprocess creation and management.
///
/// Provides low-level process execution for recipe lines.
/// Commands are run via `/bin/sh -c` on POSIX systems.
module antelope.shell.process;

import std.process : spawnProcess, wait;
import std.string : indexOf;

/// Run a command via shell and return its exit code.
///
/// If `command` is empty, returns 0 immediately without spawning.
/// The shell used is determined by the SHELL environment variable,
/// defaulting to /bin/sh if not set.
/// If `environment` is non-empty, it is parsed as KEY=VALUE pairs and
/// passed as the process environment; otherwise the parent
/// process environment is inherited.
/// Stdout and stderr are inherited from the parent (not captured here).
/// Returns: the exit code of the command, or -1 if spawning failed.
int runProcess(string command, string[] environment)
{
    if (command.length == 0)
        return 0;

    // Determine shell — respect SHELL variable, default to /bin/sh
    string shell = "/bin/sh";
    foreach (env; environment)
    {
        if (env.length > 6 && env[0..6] == "SHELL=")
        {
            shell = env[6..$];
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
    catch (Exception e)
    {
        return -1;
    }
}

unittest
{
    assert(runProcess("echo hello", []) == 0);
    assert(runProcess("exit 42", []) == 42);
}
