/// Output buffering for parallel builds.
///
/// When multiple targets build concurrently, interleaved stdout/stderr
/// produces unreadable output.  This module buffers each job's output
/// and prints it atomically when the job completes, keeping the build
/// log coherent even under full parallelism.
///
/// All methods are single-threaded — they're called exclusively from
/// the coordinator (main thread) after receiving results from workers.
/// Workers capture output locally and send it via JobDone messages;
/// no OutputManager access occurs in worker threads.
module antelope.build.output;

import std.stdio : writeln, stderr;

/// Manages per-target output buffering and atomic flush.
///
/// Two modes are supported:
///   `buffered` — Output is captured per target and printed atomically
///                when the target finishes building.  This is the default
///                for parallel builds and produces clean, readable logs.
///   `live`     — Output is printed immediately as it arrives.  Multiple
///                concurrent targets will interleave their output
///                (GNU Make's default behaviour with `-j`).
class OutputManager
{
    /// Whether to buffer output (true) or print live (false).
    bool buffered = true;

private:
    /// Per-target output buffers, keyed by target name.
    string[][string] stdoutBufs;
    string[][string] stderrBufs;

    /// Map of target name → whether the target printed a non-@ line.
    /// Used for GNU Make `-s` / `--silent` mode and @ prefix handling.
    bool[string] hadEcho;

public:
    /// Buffer a line of stdout for a target.
    void bufferStdout(string targetName, string line)
    {
        stdoutBufs[targetName] ~= line;
    }

    /// Buffer a line of stderr for a target.
    void bufferStderr(string targetName, string line)
    {
        stderrBufs[targetName] ~= line;
    }

    /// Record that the target printed (or would print) a command line.
    /// Used to suppress "nothing to be done" messages when commands were echoed.
    void markEchoed(string targetName)
    {
        hadEcho[targetName] = true;
    }

    /// Check whether the target echoed any command lines.
    bool hasEchoed(string targetName)
    {
        return (targetName in hadEcho) !is null;
    }

    /// Print a line immediately without buffering (live mode fallback).
    void printLive(string line)
    {
        writeln(line);
    }

    /// Print all buffered output for a completed target.
    ///
    /// Stdout lines are printed first, then stderr.
    /// Called by the coordinator after a worker reports completion.
    void flush(string targetName)
    {
        string[] stdoutLines;
        string[] stderrLines;

        auto soPtr = targetName in stdoutBufs;
        if (soPtr)
        {
            stdoutLines = *soPtr;
            stdoutBufs.remove(targetName);
        }
        auto sePtr = targetName in stderrBufs;
        if (sePtr)
        {
            stderrLines = *sePtr;
            stderrBufs.remove(targetName);
        }

        if (stdoutLines.length == 0 && stderrLines.length == 0)
            return;

        foreach (line; stdoutLines)
            writeln(line);

        if (stderrLines.length > 0)
        {
            foreach (line; stderrLines)
                stderr.writeln(line);
            stderr.flush();
        }
    }

    /// Clear all buffers without printing (used on failure cleanup).
    void clearAll()
    {
        stdoutBufs = null;
        stderrBufs = null;
        hadEcho = null;
    }
}

///
unittest
{
    auto om = new OutputManager();

    // Buffered mode: nothing printed during buffering
    om.bufferStdout("foo.o", "cc -c foo.c");
    om.bufferStdout("foo.o", "foo.c: In function 'main':");
    om.bufferStderr("foo.o", "foo.c:5: warning: unused variable 'x'");

    // Flush should produce all lines in order
    om.flush("foo.o");

    // After flush, buffers are empty — second flush is a no-op
    om.flush("foo.o");

    // Live mode: serialized printing
    om.buffered = false;
    om.printLive("live output line");
}

///
unittest
{
    auto om = new OutputManager();

    // Multiple targets interleaved buffering
    om.bufferStdout("a", "building a");
    om.bufferStdout("b", "building b");
    om.bufferStdout("a", "a done");

    om.flush("a");
    om.flush("b");

    // echo tracking
    om.markEchoed("c");
    assert(om.hasEchoed("c"));
    assert(!om.hasEchoed("nonexistent"));
}
