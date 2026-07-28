/// Error types and structured error reporting.
module antelope.diagnostics.errors;

/// Categories of errors Antelope can produce.
enum ErrorKind
{
    parseError,
    undefinedVariable,
    cyclicDependency,
    missingTarget,
    commandFailed,
    fileNotFound,
    internalError,
}

/// A structured error with location information.
struct AntelopeError
{
    ErrorKind kind;
    string message;
    string file;
    size_t line;
    size_t column;
}
