/// Integration test: parser handles full Makefile syntax.
module antelope.tests.integration.parse_test;

import antelope.parser.parser;
import antelope.parser.ast;

unittest
{
    // Test parsing a complete Makefile
    string makefile = "CC = gcc\nall: hello\nhello: hello.c\n\t$(CC) -o $@ $<\nclean: ; rm -f hello\n";
    auto ast = parse(makefile);
    assert(ast.type == AstType.rule_list);
    assert(ast.children.length >= 2);

    // Find the variable assignment
    bool foundVar = false;
    bool foundRule = false;
    foreach (child; ast.children)
    {
        if (child.type == AstType.variable_assignment)
            foundVar = true;
        if (child.type == AstType.rule)
            foundRule = true;
    }
    assert(foundVar, "Should find variable assignment");
    assert(foundRule, "Should find rule");
}
