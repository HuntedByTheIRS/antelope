/// Variable parsing and substitution logic.
module antelope.parser.variables;

/// Variable reference types: $(VAR), ${VAR}, $@, etc.
enum VarRefType
{
    simple,     /// $(VAR)
    brace,      /// ${VAR}
    automatic,  /// $@, $<, $^, etc.
}

/// A parsed variable reference.
struct VariableRef
{
    VarRefType refType;
    string name;
}
