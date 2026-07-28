/// Parser support for Makefile directives (include, ifdef, ifeq, etc.).
module antelope.parser.directives;

/// Supported directives.
enum DirectiveType
{
    include,
    define,
    undefine,
    ifdef,
    ifndef,
    ifeq,
    ifneq,
    else_,
    endif,
    export_,
    unexport,
    vpath,
}
