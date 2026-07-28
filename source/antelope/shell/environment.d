/// Environment variable management — inheriting, overriding, exporting.
module antelope.shell.environment;

import std.process : environment;
import antelope.compatibility.target_vars;

/// Key-value store for environment variables.
///
/// Mirrors GNU Make's variable environment: stores key-value pairs,
/// tracks which variables are exported to child processes, and can
/// be seeded from the OS environment on startup.
struct Environment
{
    private string[string] vars;
    private bool[string] exported;
    private ScopedVariable[] scopedVars;

    /// Get a variable value.
    /// Returns: the value, or `""` (empty string) if undefined.
    ///          GNU Make treats unset variables as empty strings.
    string get(string key)
    {
        return key in vars ? vars[key] : "";
    }

    /// Return all stored variable keys.
    string[] keys()
    {
        return vars.keys;
    }

    /// Set a variable value.
    void set(string key, string value)
    {
        vars[key] = value;
    }

    /// Export a variable to child processes.
    /// Marked variables are included in the environment block
    /// passed to sub-make and other spawned processes.
    void exportVar(string key)
    {
        exported[key] = true;
    }

    /// Retrieve all exported variables as an associative array.
    /// Only variables marked via `exportVar` are returned.
    string[string] getExportedVars()
    {
        string[string] result;
        foreach (key; exported.keys)
        {
            if (key in vars)
                result[key] = vars[key];
        }
        return result;
    }

    /// Merge entries from an external environment map.
    /// Typically called with `environment.toAA()` to seed the store
    /// with the OS environment on startup.
    void mergeEnv(string[string] envp)
    {
        foreach (key, value; envp)
        {
            vars[key] = value;
        }
    }

    /// Check whether a variable exists in the store.
    /// Returns: `true` if the key has been set (including via `mergeEnv`).
    bool hasKey(string key)
    {
        return (key in vars) !is null;
    }

    /// Add a target-specific variable override.
    ///
    /// When a Makefile declares `target: VAR = value`, VAR takes this value
    /// only when building `target`.  The override is stored here and
    /// consulted by `getScoped` during recipe expansion.
    void addScopedVar(string targetPattern, string name, string value,
                      bool recursive)
    {
        ScopedVariable sv;
        sv.targetPattern = targetPattern;
        sv.name = name;
        sv.value = value;
        sv.recursive = recursive;
        sv.varScope = TargetVarScope.targetSpecific;
        scopedVars ~= sv;
    }

    /// Get a variable value, checking target-scoped overrides first.
    ///
    /// When `targetName` is non-empty, all scoped-variable records that
    /// match both the variable name and the target pattern are checked
    /// before falling back to the global variable store.
    ///
    /// Params:
    ///   key        = Variable name to look up
    ///   targetName = Current target being built (empty = global lookup only)
    ///
    /// Returns: the scoped value if a match exists; otherwise the global
    ///          value (which is `""` when the variable is unset).
    string getScoped(string key, string targetName = "")
    {
        if (targetName.length > 0)
        {
            foreach (sv; scopedVars)
            {
                if (sv.name == key && sv.targetPattern == targetName)
                    return sv.value;
            }
        }
        return get(key);
    }
}

///
unittest
{
    import std.stdio : writeln;

    // --- set / get roundtrip ---
    Environment env;
    env.set("FOO", "bar");
    assert(env.get("FOO") == "bar", "set/get roundtrip failed");

    // --- undefined variable returns empty string ---
    assert(env.get("NONEXISTENT") == "", "undefined var should return empty string");

    // --- hasKey ---
    assert(env.hasKey("FOO"), "hasKey should return true for set var");
    assert(!env.hasKey("BAR"), "hasKey should return false for unset var");

    // --- export tracking ---
    env.set("EXPORTED_VAR", "value1");
    env.set("NOT_EXPORTED", "value2");
    env.exportVar("EXPORTED_VAR");

    string[string] exported = env.getExportedVars();
    assert(exported.length == 1, "only one var should be exported");
    assert("EXPORTED_VAR" in exported, "EXPORTED_VAR should be in exported set");
    assert(exported["EXPORTED_VAR"] == "value1", "exported value should match");

    // --- mergeEnv ---
    Environment env2;
    env2.mergeEnv(["PATH": "/usr/bin", "HOME": "/root"]);
    assert(env2.get("PATH") == "/usr/bin", "mergeEnv should copy PATH");
    assert(env2.get("HOME") == "/root", "mergeEnv should copy HOME");
    assert(env2.get("SHELL") == "", "unmerged var should be empty");

    writeln("All environment tests passed.");
}

///
unittest
{
    // --- scoped variable lookup ---
    Environment env;
    env.set("CFLAGS", "-O2");

    // Target-specific override
    env.addScopedVar("debug.o", "CFLAGS", "-O0 -g", true);

    // Global lookup
    assert(env.getScoped("CFLAGS") == "-O2",
           "global CFLAGS should be -O2");

    // Target-specific lookup — match
    assert(env.getScoped("CFLAGS", "debug.o") == "-O0 -g",
           "debug.o CFLAGS should be -O0 -g");

    // Target-specific lookup — no match (different target)
    assert(env.getScoped("CFLAGS", "release.o") == "-O2",
           "release.o should fall back to global CFLAGS");

    // Non-existent key
    assert(env.getScoped("NONEXIST") == "",
           "non-existent key should return empty string");
}
