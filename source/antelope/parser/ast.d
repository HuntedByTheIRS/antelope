/// Abstract Syntax Tree node definitions.
module antelope.parser.ast;

/// All node kinds in the AST.
enum AstType
{
    rule_list,
    rule,
    prerequisite,
    recipe_line,
    variable_assignment,
    directive,
    function_call,
}

/// A node in the AST.
struct AstNode
{
    AstType type;
    AstNode[] children;
    string data;
}
