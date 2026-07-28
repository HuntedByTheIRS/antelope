/// Lexical analysis for Antelope build files.
///
/// Tokenizes GNU Make-compatible syntax including tab-prefixed recipe lines,
/// backslash-newline line continuations, `#` comments, variable references,
/// and all Makefile operators.
module antelope.parser.lexer;

import antelope.diagnostics.errors;

/// Token kinds recognized by the lexer.
enum TokenType
{
    identifier,
    colon,
    doubleColon,      /// `::` — double-colon rules
    equals,           /// `=` — recursive assignment
    plusEquals,       /// `+=` — append assignment
    colonEquals,      /// `:=` — immediate assignment
    questionEquals,   /// `?=` — conditional assignment
    dollar,           /// `$` — variable/function reference prefix
    lparen,           /// `(`
    rparen,           /// `)`
    lbrace,           /// `{`
    rbrace,           /// `}`
    pipe,             /// `|` — order-only prerequisite separator
    comma,            /// `,` — function argument separator
    semicolon,        /// `;` — inline recipe separator
    hash,             /// `#` — comment prefix (not emitted; comments produce newline)
    newline,          /// end of logical line
    eof,              /// end of input
    tab,              /// column-0 tab — recipe line indicator
}

/// A single token from the input.
struct Token
{
    TokenType type;
    string value;
    size_t line;
    size_t column;
}

/// Returns true if `c` is a valid character inside an identifier.
private static bool isIdentChar(char c)
{
    import std.ascii : isAlphaNum;
    switch (c)
    {
        case '-', '_', '.', '/', '+', '?', '%', '*', '~', '\\', '@', '<', '^':
            return true;
        default:
            return isAlphaNum(c);
    }
}

/// Lexer state.
struct Lexer
{
    string input;
    size_t pos;
    size_t line = 1;    /// 1-indexed
    size_t column;      /// 0-indexed
    bool done;          /// true after eof has been emitted

    /// Produce the next token from the input stream.
    Token nextToken()
    {
        if (done)
            return Token(TokenType.eof, "", line, column);

        // --- Skip whitespace and line continuations ---
        while (true)
        {
            // Skip spaces and non-BOL tabs (tabs at column != 0 are whitespace)
            while (pos < input.length)
            {
                char ch = input[pos];
                if (ch == ' ' || (ch == '\t' && column != 0))
                {
                    pos++;
                    column++;
                }
                else
                {
                    break;
                }
            }

            // Backslash-newline: line continuation — consume both and restart
            if (pos < input.length && input[pos] == '\\' &&
                pos + 1 < input.length && input[pos + 1] == '\n')
            {
                pos += 2;
                line++;
                column = 0;
                continue;
            }

            break;
        }

        // --- End of input ---
        if (pos >= input.length)
        {
            done = true;
            return Token(TokenType.eof, "", line, column);
        }

        // --- Tab at column 0 signals a recipe line ---
        if (input[pos] == '\t' && column == 0)
        {
            size_t tokLine = line;
            size_t tokCol = column;
            pos++;
            column++;
            return Token(TokenType.tab, "\t", tokLine, tokCol);
        }

        // Save position before consuming the first character
        size_t startLine = line;
        size_t startCol = column;
        char ch = input[pos];

        // --- Newline ---
        if (ch == '\n')
        {
            pos++;
            line++;
            column = 0;
            return Token(TokenType.newline, "\n", startLine, startCol);
        }

        // --- Comment: `#` to end of line (or EOF), returns newline token ---
        if (ch == '#')
        {
            while (pos < input.length && input[pos] != '\n')
            {
                pos++;
                column++;
            }
            if (pos < input.length && input[pos] == '\n')
            {
                pos++;
                line++;
                column = 0;
            }
            return Token(TokenType.newline, "", startLine, startCol);
        }

        // --- Dollar sign (variable/function reference prefix) ---
        if (ch == '$')
        {
            pos++;
            column++;
            return Token(TokenType.dollar, "$", startLine, startCol);
        }

        // --- Colon (single, double, or colon-equals) ---
        if (ch == ':')
        {
            pos++;
            column++;
            if (pos < input.length)
            {
                if (input[pos] == ':')
                {
                    pos++;
                    column++;
                    return Token(TokenType.doubleColon, "::", startLine, startCol);
                }
                if (input[pos] == '=')
                {
                    pos++;
                    column++;
                    return Token(TokenType.colonEquals, ":=", startLine, startCol);
                }
            }
            return Token(TokenType.colon, ":", startLine, startCol);
        }

        // --- Bare equals ---
        if (ch == '=')
        {
            pos++;
            column++;
            return Token(TokenType.equals, "=", startLine, startCol);
        }

        // --- Plus-equals (+=) or plus as identifier start ---
        if (ch == '+')
        {
            if (pos + 1 < input.length && input[pos + 1] == '=')
            {
                pos += 2;
                column += 2;
                return Token(TokenType.plusEquals, "+=", startLine, startCol);
            }
            // Not += — fall through to identifier accumulation with + as first char
        }

        // --- Question-equals (?=) or question as identifier start ---
        if (ch == '?')
        {
            if (pos + 1 < input.length && input[pos + 1] == '=')
            {
                pos += 2;
                column += 2;
                return Token(TokenType.questionEquals, "?=", startLine, startCol);
            }
            // Not ?= — fall through to identifier accumulation with ? as first char
        }

        // --- Single-character tokens ---
        switch (ch)
        {
            case '|':
                pos++; column++;
                return Token(TokenType.pipe, "|", startLine, startCol);
            case ',':
                pos++; column++;
                return Token(TokenType.comma, ",", startLine, startCol);
            case ';':
                pos++; column++;
                return Token(TokenType.semicolon, ";", startLine, startCol);
            case '(':
                pos++; column++;
                return Token(TokenType.lparen, "(", startLine, startCol);
            case ')':
                pos++; column++;
                return Token(TokenType.rparen, ")", startLine, startCol);
            case '{':
                pos++; column++;
                return Token(TokenType.lbrace, "{", startLine, startCol);
            case '}':
                pos++; column++;
                return Token(TokenType.rbrace, "}", startLine, startCol);
            default:
                break;
        }

        // --- Accumulate identifier ---
        // Build the value character-by-character so that line continuations
        // (backslash-newline pairs) are excluded from the identifier text.
        char[] buf;

        while (pos < input.length)
        {
            char c = input[pos];

            // Backslash-newline inside identifier → line continuation
            if (c == '\\' && pos + 1 < input.length && input[pos + 1] == '\n')
            {
                pos += 2;
                line++;
                column = 0;
                continue;
            }

            // += and ?= are operators; if found mid-identifier, stop here
            if ((c == '+' || c == '?') &&
                pos + 1 < input.length && input[pos + 1] == '=')
            {
                break;
            }

            if (isIdentChar(c))
            {
                buf ~= c;
                pos++;
                column++;
                continue;
            }

            break;
        }

        string value = buf.idup;
        return Token(TokenType.identifier, value, startLine, startCol);
    }
}

///
unittest
{
    // --- Basic tokens ---
    {
        auto lex = Lexer("target: prereq");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier, "expected identifier");
        assert(t.value == "target");
        assert(t.line == 1);
        assert(t.column == 0);

        t = lex.nextToken();
        assert(t.type == TokenType.colon);
        assert(t.value == ":");

        t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "prereq");
        assert(t.column == 8);
    }

    // --- Tab detection at column 0 ---
    {
        auto lex = Lexer("\trecipe line");
        auto t = lex.nextToken();
        assert(t.type == TokenType.tab, "column-0 tab should produce tab token");
        assert(t.line == 1);
        assert(t.column == 0);

        t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "recipe");
    }

    // --- Tab not at column 0 is whitespace ---
    {
        auto lex = Lexer("target: \tprereq");
        auto t = lex.nextToken(); // target
        t = lex.nextToken();      // :
        t = lex.nextToken();      // prereq (tab skipped as whitespace)
        assert(t.type == TokenType.identifier);
        assert(t.value == "prereq");
    }

    // --- Backslash-newline continuation ---
    {
        auto lex = Lexer("foo\\\nbar");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "foobar", "line continuation should join identifiers");
        assert(t.line == 1, "token should report starting line");
    }

    // --- Comment to end of line ---
    {
        auto lex = Lexer("# this is a comment\nnextline");
        auto t = lex.nextToken();
        assert(t.type == TokenType.newline, "comment should produce newline");
        assert(t.line == 1);

        t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "nextline");
        assert(t.line == 2);
    }

    // --- Comment at EOF (no trailing newline) ---
    {
        auto lex = Lexer("# comment at eof");
        auto t = lex.nextToken();
        assert(t.type == TokenType.newline);
    }

    // --- Line / column tracking ---
    {
        auto lex = Lexer("line1\n  line2");
        auto t = lex.nextToken();
        assert(t.value == "line1");
        assert(t.line == 1);

        t = lex.nextToken();
        assert(t.type == TokenType.newline);
        assert(t.line == 1);

        t = lex.nextToken();
        assert(t.value == "line2");
        assert(t.line == 2);
        assert(t.column == 2);
    }

    // --- Empty input ---
    {
        auto lex = Lexer("");
        auto t = lex.nextToken();
        assert(t.type == TokenType.eof);

        t = lex.nextToken();
        assert(t.type == TokenType.eof, "subsequent calls after eof must return eof");
    }

    // --- Double colon ---
    {
        auto lex = Lexer("target:: prereq");
        auto t = lex.nextToken();
        assert(t.value == "target");

        t = lex.nextToken();
        assert(t.type == TokenType.doubleColon);
        assert(t.value == "::");
    }

    // --- All assignment operators ---
    {
        // Simple =
        auto lex = Lexer("VAR = val");
        auto t = lex.nextToken(); // VAR
        t = lex.nextToken();
        assert(t.type == TokenType.equals);
        assert(t.value == "=");
    }
    {
        // Immediate :=
        auto lex = Lexer("VAR := val");
        auto t = lex.nextToken(); // VAR
        t = lex.nextToken();
        assert(t.type == TokenType.colonEquals);
        assert(t.value == ":=");
    }
    {
        // Append +=
        auto lex = Lexer("VAR += val");
        auto t = lex.nextToken(); // VAR
        t = lex.nextToken();
        assert(t.type == TokenType.plusEquals);
        assert(t.value == "+=");
    }
    {
        // Conditional ?=
        auto lex = Lexer("VAR ?= val");
        auto t = lex.nextToken(); // VAR
        t = lex.nextToken();
        assert(t.type == TokenType.questionEquals);
        assert(t.value == "?=");
    }

    // --- Dollar, parens, braces ---
    {
        auto lex = Lexer("$(VAR) ${VAR}");
        auto t = lex.nextToken();
        assert(t.type == TokenType.dollar);

        t = lex.nextToken();
        assert(t.type == TokenType.lparen);

        t = lex.nextToken();
        assert(t.value == "VAR");

        t = lex.nextToken();
        assert(t.type == TokenType.rparen);

        t = lex.nextToken();
        assert(t.type == TokenType.dollar);

        t = lex.nextToken();
        assert(t.type == TokenType.lbrace);

        t = lex.nextToken();
        assert(t.value == "VAR");

        t = lex.nextToken();
        assert(t.type == TokenType.rbrace);
    }

    // --- Pipe, comma, semicolon ---
    {
        auto lex = Lexer("a | b , c ; d");
        auto t = lex.nextToken(); // a
        t = lex.nextToken();
        assert(t.type == TokenType.pipe);
        t = lex.nextToken();      // b
        assert(t.value == "b");
        t = lex.nextToken();
        assert(t.type == TokenType.comma);
        t = lex.nextToken();      // c
        assert(t.value == "c");
        t = lex.nextToken();
        assert(t.type == TokenType.semicolon);
        t = lex.nextToken();      // d
        assert(t.value == "d");
    }

    // --- Identifier with special chars ---
    {
        auto lex = Lexer("foo-bar_baz.dir/file%*.c~");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "foo-bar_baz.dir/file%*.c~");
    }

    // --- Plus in identifier (not followed by =) ---
    {
        auto lex = Lexer("g++ main.c");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "g++");

        t = lex.nextToken();
        assert(t.value == "main.c");
    }

    // --- Question in identifier (not followed by =) ---
    {
        auto lex = Lexer("file?");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "file?");
    }

    // --- Backslash-newline inside identifier ---
    {
        auto lex = Lexer("foo\\\nbar");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "foobar");
        assert(t.line == 1);
    }

    // --- Multiple line continuations ---
    {
        auto lex = Lexer("a\\\n\\\nb");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "ab");
        assert(t.line == 1); // starts on line 1 even if it spans 3 lines
    }

    // --- Backslash literal (not followed by newline) ---
    {
        auto lex = Lexer("foo\\bar");
        auto t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "foo\\bar");
    }

    // --- Dollar as variable prefix ---
    {
        auto lex = Lexer("$@ $< $^");
        auto t = lex.nextToken();
        assert(t.type == TokenType.dollar);
        t = lex.nextToken();
        assert(t.type == TokenType.identifier);
        assert(t.value == "@");
    }
}
