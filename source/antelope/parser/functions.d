/// Parsing for GNU Make function calls: $(func ...).
module antelope.parser.functions;

/// Known GNU Make functions.
enum BuiltinFunction
{
    subst,
    patsubst,
    strip,
    findstring,
    filter,
    filter_out,
    sort,
    word,
    words,
    wordlist,
    firstword,
    lastword,
    dir,
    notdir,
    suffix,
    basename,
    addsuffix,
    addprefix,
    join,
    wildcard,
    realpath,
    abspath,
    shell,
    error,
    warning,
    info,
    foreach_,
    call,
    value,
    origin,
    flavor,
    or_,
    and_,
}

/// A parsed function call.
struct FunctionCall
{
    BuiltinFunction func;
    string[] arguments;
}
