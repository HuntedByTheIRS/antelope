/// Unit tests for the Antelope parser.
///
/// Tests recursive-descent parsing of rules, variable assignments,
/// and directive blocks into the AST.
module antelope.tests.parser.parser_test;

import antelope.parser.parser;
import antelope.parser.ast;

/// Test parsing a simple rule with prerequisites and no recipe.
unittest
{
    auto root = parseMakefile("target: prereq1 prereq2\n");
    assert(root.type == AstType.rule_list);
    assert(root.children.length == 1);

    auto rule = root.children[0];
    assert(rule.type == AstType.rule);
}

/// Test parsing a variable assignment.
unittest
{
    auto root = parseMakefile("CC = gcc\n");
    assert(root.type == AstType.rule_list);
    assert(root.children.length == 1);

    auto var = root.children[0];
    assert(var.type == AstType.variable_assignment);
}
