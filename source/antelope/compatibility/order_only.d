/// GNU Make order-only prerequisites (|) — must exist but don't trigger rebuilds.
///
/// GNU Make supports order-only prerequisites via the pipe (|) separator.
/// Prerequisites after the pipe must exist and be up-to-date before the
/// target is built, but they do NOT cause the target to be considered out
/// of date when they change.
///
/// Antelope rule syntax:
///   target: prereqs... | order-only-prereqs...
module antelope.compatibility.order_only;

/// A set of prerequisites split into normal and order-only.
struct PrereqSplit
{
    string[] normal;
    string[] orderOnly;
}

/// Split a flat prerequisite list at the first | separator.
PrereqSplit splitPrereqs(string[] allPrereqs)
{
    PrereqSplit result;
    bool pastPipe;
    foreach (p; allPrereqs)
    {
        if (p == "|")
            pastPipe = true;
        else if (pastPipe)
            result.orderOnly ~= p;
        else
            result.normal ~= p;
    }
    return result;
}
