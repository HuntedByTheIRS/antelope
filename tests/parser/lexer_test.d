/// Unit tests for the Antelope lexer.
///
/// Tests tokenization of Makefile syntax: identifiers, operators,
/// variable references, comments, recipe lines, and line continuations.
module antelope.tests.parser.lexer_test;

import antelope.parser.lexer;

/// Test basic identifier and operator tokenization.
unittest
{
    auto lexer = Lexer("target: prereq\n");
    auto tok = lexer.nextToken();
    assert(tok.type == TokenType.identifier);
    assert(tok.value == "target");

    tok = lexer.nextToken();
    assert(tok.type == TokenType.colon);

    tok = lexer.nextToken();
    assert(tok.type == TokenType.identifier);
    assert(tok.value == "prereq");
}

/// Test comment stripping — everything after '#' is ignored.
unittest
{
    auto lexer = Lexer("VAR = value # this is a comment\n");
    auto tok = lexer.nextToken();
    assert(tok.type == TokenType.identifier);
    assert(tok.value == "VAR");

    tok = lexer.nextToken();
    assert(tok.type == TokenType.equals);

    tok = lexer.nextToken();
    assert(tok.type == TokenType.identifier);
    assert(tok.value == "value");
}

/// Test line continuation (backslash-newline).
unittest
{
    auto lexer = Lexer("target: prereq1 \\\n        prereq2\n");
    auto tok = lexer.nextToken();
    assert(tok.type == TokenType.identifier);
    assert(tok.value == "target");

    tok = lexer.nextToken();
    assert(tok.type == TokenType.colon);
}

/// Test variable reference prefix ($).
unittest
{
    auto lexer = Lexer("$(VAR)\n");
    auto tok = lexer.nextToken();
    assert(tok.type == TokenType.dollar);
}

/// Test recipe line detection (tab-prefixed).
unittest
{
    auto lexer = Lexer("\tgcc -c hello.c\n");
    auto tok = lexer.nextToken();
    assert(tok.type == TokenType.recipeLine);
}
