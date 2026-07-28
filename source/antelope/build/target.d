/// Target representation — files, phony targets, and their metadata.
module antelope.build.target;

/// What kind of target this is.
enum TargetKind
{
    file,
    phony,
    intermediate,
}

/// A single build target.
struct Target
{
    string name;
    TargetKind kind;
    string[] prerequisites;        /// Normal prerequisites (trigger rebuild)
    string[] recipe;               /// Shell commands to build this target
    string[] orderOnlyPrereqs;     /// Order-only prerequisites (| — must exist, no rebuild trigger)
}
