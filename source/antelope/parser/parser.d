/// Recursive-descent parser for Makefile syntax.
///
/// Consumes tokens from the lexer to produce an AST following
/// GNU Make grammar rules. Supports rules, variable assignments,
/// conditional blocks, and directives.
module antelope.parser.parser;

import std.conv : to;
import std.string : strip, stripLeft, startsWith;
import std.array : join;
import antelope.parser.lexer;
import antelope.parser.ast;

/// Parse a string containing Makefile syntax into an AST.
///
/// Creates a Lexer internally and drives the recursive-descent parser.
/// Returns an AstNode of type `rule_list` containing all top-level
/// statements as children.
///
/// Params:
///   input = Raw Makefile source text
/// Returns:
///   Root AST node with complete parse tree
AstNode parse(string input)
{
    auto lexer = Lexer(input);
    Parser parser;
    parser.lexer = lexer;
    return parser.parseMakefile();
}

/// Internal parser state tracking the token stream.
private struct Parser
{
    Lexer lexer;
    Token current;   /// Current lookahead token
    Token previous;  /// Most recently consumed token

    // -----------------------------------------------------------------------
    // Token stream helpers
    // -----------------------------------------------------------------------

    /// Advance to the next token, returning the previously-current token.
    Token advance()
    {
        previous = current;
        current = lexer.nextToken();
        return previous;
    }

    /// True when current token has the given type.
    bool check(TokenType t) const
    {
        return current.type == t;
    }

    /// True when current token is an identifier with the given value.
    bool checkIdent(string value) const
    {
        return current.type == TokenType.identifier && current.value == value;
    }

    /// True when lexer position has a backslash-newline continuation.
    bool isBackslashNewline() const
    {
        return lexer.pos + 1 < lexer.input.length &&
               lexer.input[lexer.pos] == '\\' &&
               lexer.input[lexer.pos + 1] == '\n';
    }

    /// Consume current token; throw if it doesn't match the expected type.
    Token eat(TokenType t, string errMsg)
    {
        if (!check(t))
            throw new Exception(errMsg ~ " (got '" ~ current.value ~
                "' at line " ~ current.line.to!string ~ ")");
        return advance();
    }

    /// Skip consecutive newline tokens (blank lines and comments).
    void skipNewlines()
    {
        while (check(TokenType.newline))
            advance();
    }

    // -----------------------------------------------------------------------
    // Raw line reader — used for recipe text, variable values, directive args
    // -----------------------------------------------------------------------

    /// Read raw characters from the lexer input until end of line or EOF.
    ///
    /// Handles backslash-newline line continuations inside the raw text.
    /// Does NOT consume the terminating newline; leaves it for the token
    /// stream to process. Updates lexer position/line/column tracking.
    string readRawLine()
    {
        char[] buf;
        while (lexer.pos < lexer.input.length)
        {
            char c = lexer.input[lexer.pos];

            // Backslash-newline — line continuation
            if (c == '\\' && lexer.pos + 1 < lexer.input.length &&
                lexer.input[lexer.pos + 1] == '\n')
            {
                lexer.pos += 2;
                lexer.line++;
                lexer.column = 0;
                continue;
            }

            // Unescaped newline ends the raw line
            if (c == '\n')
                break;

            buf ~= c;
            lexer.pos++;
            lexer.column++;
        }
        return buf.idup;
    }

    // -----------------------------------------------------------------------
    // Prerequisite text accumulation
    // -----------------------------------------------------------------------

    /// Accumulate a single prerequisite token group.
    ///
    /// Simple identifiers are returned as-is. Variable references ($@,
    /// $(VAR), ${VAR}) are accumulated through their matching paren/brace
    /// to produce the complete reference string (e.g. "$(VAR)").
    string accumulatePrereq()
    {
        if (check(TokenType.dollar))
        {
            string result = advance().value; // "$"

            if (check(TokenType.identifier))
            {
                result ~= advance().value; // $@, $<, $^, etc.
            }
            else if (check(TokenType.lparen))
            {
                result ~= advance().value; // "("
                int depth = 1;
                while (depth > 0 && !check(TokenType.eof) &&
                       !check(TokenType.newline) && !check(TokenType.tab))
                {
                    if (check(TokenType.lparen))
                    {
                        depth++;
                        result ~= advance().value;
                    }
                    else if (check(TokenType.rparen))
                    {
                        depth--;
                        if (depth > 0)
                            result ~= advance().value;
                    }
                    else
                    {
                        // Lexer skips whitespace — add a space between
                        // tokens to preserve $(func arg1 arg2) syntax.
                        if (result[$-1] != '(' && result[$-1] != ' ')
                            result ~= ' ';
                        result ~= advance().value;
                    }
                }
                if (check(TokenType.rparen))
                    result ~= advance().value; // ")"
            }
            else if (check(TokenType.lbrace))
            {
                result ~= advance().value; // "{"
                int depth = 1;
                while (depth > 0 && !check(TokenType.eof) &&
                       !check(TokenType.newline) && !check(TokenType.tab))
                {
                    if (check(TokenType.lbrace))
                    {
                        depth++;
                        result ~= advance().value;
                    }
                    else if (check(TokenType.rbrace))
                    {
                        depth--;
                        if (depth > 0)
                            result ~= advance().value;
                    }
                    else
                    {
                        // Same: preserve whitespace between tokens
                        if (result[$-1] != '{' && result[$-1] != ' ')
                            result ~= ' ';
                        result ~= advance().value;
                    }
                }
                if (check(TokenType.rbrace))
                    result ~= advance().value; // "}"
            }
            return result;
        }
        else
        {
            return advance().value;
        }
    }

    // -----------------------------------------------------------------------
    // Top-level driver
    // -----------------------------------------------------------------------

    /// Parse the entire token stream into a rule_list AST node.
    AstNode parseMakefile()
    {
        auto root = AstNode(AstType.rule_list);
        current = lexer.nextToken();
        skipNewlines();

        while (!check(TokenType.eof))
        {
            auto stmt = parseStatement();
            // Skip dummy nodes returned for empty/whitespace lines
            if (stmt.type != AstType.rule_list || stmt.children.length > 0)
                root.children ~= stmt;
            skipNewlines();
        }

        return root;
    }

    // -----------------------------------------------------------------------
    // Statement dispatch
    // -----------------------------------------------------------------------

    /// Parse a single top-level statement: rule, variable, conditional,
    /// directive, or error.
    AstNode parseStatement()
    {
        // Tab without preceding rule: in GNU Make, tabs inside conditionals
        // are just indentation. Consume the tab and retry as a normal statement.
        if (check(TokenType.tab))
        {
            advance(); // consume tab
            return parseStatement(); // retry
        }

        // Blank line / EOF
        if (check(TokenType.newline) || check(TokenType.eof))
        {
            advance();
            return AstNode(AstType.rule_list);
        }

        // Statements start with an identifier or variable reference ($)
        if (!check(TokenType.identifier) && !check(TokenType.dollar))
        {
            throw new Exception(
                "Unexpected token '" ~ current.value ~
                "' at line " ~ current.line.to!string);
        }

        // --- Directive keywords — checked BEFORE buffering identifiers ---
        // These consume their arguments via readRawLine() so that the raw
        // text after the keyword is captured before any token advancement.

        // Conditional block openers: consume keyword, read args, parse body
        if (checkIdent("ifdef") || checkIdent("ifndef") ||
            checkIdent("ifeq") || checkIdent("ifneq"))
        {
            string kw = current.value;
            // lexer.pos is right after the keyword — read args until newline
            string args = readRawLine();
            advance(); // consume the newline (or eof) after the args
            return parseConditional(kw, args);
        }

        // define: multi-line variable definition — capture body up to endef
        // Must be handled BEFORE the generic directive block so that the
        // body lines (which may look like identifiers) are not tokenized.
        if (checkIdent("define"))
        {
            string kw = current.value;
            string args = readRawLine();   // read variable name after "define"
            advance();                      // consume newline after define line

            string varName = args.strip;

            // Read raw lines from the input until a line starting with
            // "endef" is found.  The body is stored as literal text — no
            // tokenization is applied to the lines between define and endef.
            string[] bodyLines;
            while (lexer.pos < lexer.input.length)
            {
                string line = readRawLine();

                if (stripLeft(line).startsWith("endef"))
                {
                    // Consume the newline after endef
                    if (lexer.pos < lexer.input.length &&
                        lexer.input[lexer.pos] == '\n')
                    {
                        lexer.pos++;
                        lexer.line++;
                        lexer.column = 0;
                    }
                    break;
                }

                bodyLines ~= line;

                // Consume the newline after this body line
                if (lexer.pos < lexer.input.length &&
                    lexer.input[lexer.pos] == '\n')
                {
                    lexer.pos++;
                    lexer.line++;
                    lexer.column = 0;
                }
                else if (lexer.pos >= lexer.input.length)
                {
                    throw new Exception(
                        "Unterminated define block: missing 'endef' at line " ~
                        lexer.line.to!string);
                }
            }

            string body = bodyLines.join("\n");

            auto node = AstNode(AstType.variable_assignment);
            node.data = varName ~ "=" ~ body;
            return node;
        }

        // Standalone directives: consume keyword, read args, done
        if (checkIdent("include") || checkIdent("sinclude") ||
            checkIdent("-include") ||
            checkIdent("vpath") ||
            checkIdent("undefine") ||
            checkIdent("export") || checkIdent("unexport"))
        {
            string kw = current.value;
            string args = readRawLine();
            advance(); // consume the newline

            auto node = AstNode(AstType.directive);
            node.data = kw ~ args; // args already includes leading space
            return node;
        }

        // else/endif should only appear inside conditionals; parse as
        // standalone directives for error robustness
        if (checkIdent("else") || checkIdent("endif"))
        {
            string kw = current.value;
            // No args — just the keyword on a line
            advance(); // consume the keyword
            if (check(TokenType.newline))
                advance();

            auto node = AstNode(AstType.directive);
            node.data = kw;
            return node;
        }

        // --- Rules and variable assignments: buffer identifiers ---
        // At this point current is still the first identifier, untouched.
        // Buffer identifiers and variable references as potential targets
        Token[] idents;
        while (check(TokenType.identifier))
            idents ~= advance();
        // Also collect $ references like $(OBJS) — reused from prereq parsing
        while (idents.length == 0 || (check(TokenType.dollar) && idents.length >= 0))
        {
            if (!check(TokenType.dollar))
                break;
            string value = accumulatePrereq();
            // If we already have a token and it ends with a non-space character
            // (like `src/ar.`), merge the $() result into it instead of creating
            // a new token. This produces `src/ar.$(OBJEXT)` not `src/ar. $(OBJEXT)`.
            if (idents.length > 0)
                idents[$-1].value ~= value;
            else
            {
                Token t;
                t.type = TokenType.identifier;
                t.value = value;
                t.line = current.line;
                t.column = current.column;
                idents ~= t;
            }
            // Merge trailing text after $() into same token: $(srcdir)/Makefile.in
            while (check(TokenType.identifier) || check(TokenType.dollar))
            {
                if (check(TokenType.dollar) && idents[$-1].value[$-1] != '(' && idents[$-1].value[$-1] != ')')
                    break;
                if (check(TokenType.dollar))
                    idents[$-1].value ~= accumulatePrereq();
                else
                    idents[$-1].value ~= advance().value;
            }
        }

        // Variable assignment: exactly one identifier followed by operator
        if (idents.length == 1 &&
            (check(TokenType.equals) || check(TokenType.colonEquals) ||
             check(TokenType.plusEquals) || check(TokenType.questionEquals)))
        {
            Token op = current; // capture operator WITHOUT advancing
            return parseVariableAssignment(idents[0], op);
        }

        // Rule: identifiers followed by colon (single or double)
        if (check(TokenType.colon) || check(TokenType.doubleColon))
            return parseRule(idents);

        // If none of the above, skip the unknown line silently.
        // This handles bodies of define/endef blocks and other non-syntax
        // content. Consume tokens until newline.
        while (!check(TokenType.newline) && !check(TokenType.eof))
            advance();
        if (check(TokenType.newline))
            advance();
        return AstNode(AstType.rule_list);
    }

    // -----------------------------------------------------------------------
    // Rule parsing
    // -----------------------------------------------------------------------

    /// Parse a rule: targets : prerequisites ; recipe NL (TAB recipe NL)*
    ///
    /// Params:
    ///   targets = All target-identifier tokens accumulated before the colon
    AstNode parseRule(Token[] targets)
    {
        auto colon = advance(); // colon or doubleColon

        // Store ALL target names space-separated for multi-target rules
        import std.array : join;
        import std.algorithm : map;
        string allTargets = targets.map!(t => t.value).join(" ");
        bool isDouble = (colon.type == TokenType.doubleColon);
        auto rule = AstNode(AstType.rule);
        rule.data = allTargets ~ (isDouble ? "::" : "");

        // --- Parse prerequisites until newline / semicolon / tab ---
        // When we hit `|`, continue accumulating (order-only prereqs
        // are stored the same way in the AST; the evaluator can
        // distinguish by the pipe position).
        // Tabs from backslash-continued lines are consumed as whitespace.
        while (!check(TokenType.newline) && !check(TokenType.eof) &&
               !check(TokenType.semicolon))
        {
            // Tab in the middle of prerequisites (from line continuation):
            // consume it silently and continue.
            if (check(TokenType.tab))
            {
                advance();
                continue;
            }
            if (check(TokenType.pipe))
            {
                advance(); // consume pipe token
                // Store a | marker so splitPrereqs can detect order-only prereqs
                auto pipeNode = AstNode(AstType.prerequisite);
                pipeNode.data = "|";
                rule.children ~= pipeNode;
                continue;
            }
            {
                auto prereq = AstNode(AstType.prerequisite);
                prereq.data = accumulatePrereq();
                // Merge adjacent tokens into a single prerequisite
                // when the first token was a $ reference, but stop
                // at standalone $ refs like $(OBJS) ${LIBS}.
                // Also stop if identifier text has been merged after
                // the initial $() — a subsequent $ is a new independent
                // reference (e.g., "$(srcdir)/foo $(BAR)" should be two
                // prereqs, not one concatenation).
                bool startsWithDollar = (prereq.data.length > 0 && prereq.data[0] == '$');
                if (startsWithDollar)
                {
                    bool mergedIdents;
                    while (check(TokenType.identifier) || check(TokenType.dollar))
                    {
                        // Don't merge separate standalone $ refs
                        if (check(TokenType.dollar) && (prereq.data[$-1] == ')' || prereq.data[$-1] == '}'))
                            break;
                        // Once any identifier has been merged after the $()
                        // reference (e.g., /POTFILES.in after $(srcdir)),
                        // subsequent tokens are new independent prereqs.
                        if (mergedIdents)
                            break;
                        if (check(TokenType.dollar))
                            prereq.data ~= accumulatePrereq();
                        else
                        {
                            prereq.data ~= advance().value;
                            mergedIdents = true;
                        }
                    }
                }
                rule.children ~= prereq;
            }
        }

        // --- Optional inline recipe after semicolon ---
        // NOTE: current is already semicolon (prereq loop exited on it);
        // lexer.pos is already after the ; character.
        // Do NOT advance() here — just read raw text directly.
        if (check(TokenType.semicolon))
        {
            string recipe = readRawLine();
            auto rl = AstNode(AstType.recipe_line);
            rl.data = recipe;
            rule.children ~= rl;
            advance(); // consume the newline that terminated the inline recipe
        }

        // --- Recipe lines (start with column-0 tab) ---
        // NOTE: when we enter this loop with current==tab, lexer.pos is
        // already positioned right after the \t character (the tab token
        // was consumed by an earlier advance(), not by us here).
        // So readRawLine() will start at the first character of recipe text.
        while (check(TokenType.tab) || check(TokenType.newline))
        {
            if (check(TokenType.newline))
            {
                advance(); // blank/comment line between recipe lines
                continue;
            }
            // current is tab — lexer.pos is already right after \t
            string recipe = readRawLine();
            auto rl = AstNode(AstType.recipe_line);
            rl.data = recipe;
            rule.children ~= rl;
            advance(); // consume the terminating newline
        }

        return rule;
    }

    // -----------------------------------------------------------------------
    // Variable assignment parsing
    // -----------------------------------------------------------------------

    /// Parse a variable assignment: NAME OP value
    ///
    /// Params:
    ///   name = The variable name identifier token
    ///   op   = The assignment operator token (current, not yet advanced past)
    AstNode parseVariableAssignment(Token name, Token op)
    {
        // lexer.pos is already right after the operator character
        string rawValue = readRawLine();
        // Now advance past the newline (or eof) that terminated the line
        advance();

        auto node = AstNode(AstType.variable_assignment);
        node.data = name.value ~ op.value ~ rawValue;
        return node;
    }

    // -----------------------------------------------------------------------
    // Conditional block parsing
    // -----------------------------------------------------------------------

    /// Parse a conditional block: ifXXX args NL body [else NL body] endif
    ///
    /// Params:
    ///   ifKind = The conditional keyword ("ifdef", "ifndef", "ifeq", "ifneq")
    ///   args   = Raw args text already read from the line (may be empty)
    AstNode parseConditional(string ifKind, string args)
    {
        auto dirNode = AstNode(AstType.directive);
        dirNode.data = ifKind ~ args; // args already includes leading space

        // Parse the "then" body and optional "else" branch
        parseConditionalBody(dirNode, false);

        return dirNode;
    }

    /// Parse statements inside a conditional block until `else` or `endif`.
    ///
    /// Params:
    ///   dirNode   = The directive node to append child statements to
    ///   inElse    = True if we are parsing the else-branch body already
    private void parseConditionalBody(ref AstNode dirNode, bool inElse)
    {
        while (!check(TokenType.eof))
        {
            skipNewlines();

            if (check(TokenType.eof))
                throw new Exception("Unterminated conditional block: "
                    ~ "missing 'endif'");

            // Check for `endif`
            if (checkIdent("endif"))
            {
                advance(); // endif
                if (check(TokenType.newline))
                    advance();
                return;
            }

            // Check for `else`
            if (!inElse && checkIdent("else"))
            {
                advance(); // else
                if (check(TokenType.newline))
                    advance();

                // Create an else node — populate children BEFORE
                // appending to parent (struct copy semantics!)
                auto elseNode = AstNode(AstType.directive);
                elseNode.data = "else";

                // Parse the else-branch body
                parseConditionalBody(elseNode, true);

                dirNode.children ~= elseNode;
                return;
            }

            // Normal statement in the conditional body
            auto stmt = parseStatement();
            if (stmt.type != AstType.rule_list || stmt.children.length > 0)
                dirNode.children ~= stmt;
        }
    }

}

// =======================================================================
// Unittests
// =======================================================================

/// Rule with one prerequisite and one recipe line.
unittest
{
    auto ast = parse("all: main.o\n\tcc -o all main.o");
    assert(ast.type == AstType.rule_list);
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "all");

    // One prerequisite + one recipe line = 2 children
    assert(rule.children.length == 2);
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "main.o");
    assert(rule.children[1].type == AstType.recipe_line);
    assert(rule.children[1].data == "cc -o all main.o");
}

/// Variable assignment.
unittest
{
    auto ast = parse("CC = gcc");
    assert(ast.type == AstType.rule_list);
    assert(ast.children.length == 1);

    auto var = ast.children[0];
    assert(var.type == AstType.variable_assignment);
    assert(var.data == "CC= gcc");
}

/// Variable assignment with different operators.
unittest
{
    {
        auto ast = parse("VAR := value");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "VAR:= value");
    }
    {
        auto ast = parse("VAR += append");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "VAR+= append");
    }
    {
        auto ast = parse("VAR ?= cond");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "VAR?= cond");
    }
}

/// Rule with two prerequisites.
unittest
{
    auto ast = parse("all: main.o util.o\n\tcc $^ -o $@");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "all");
    assert(rule.children.length == 3); // 2 prereqs + 1 recipe

    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "main.o");
    assert(rule.children[1].type == AstType.prerequisite);
    assert(rule.children[1].data == "util.o");
    assert(rule.children[2].type == AstType.recipe_line);
    assert(rule.children[2].data == "cc $^ -o $@");
}

/// Rule with no prerequisites (target only, with recipe).
unittest
{
    auto ast = parse("clean:\n\trm -f *.o");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "clean");
    assert(rule.children.length == 1); // only recipe
    assert(rule.children[0].type == AstType.recipe_line);
    assert(rule.children[0].data == "rm -f *.o");
}

/// Multiple rules in sequence.
unittest
{
    auto ast = parse("all: main.o\n\nclean:\n\trm -f *.o");
    assert(ast.children.length == 2);

    assert(ast.children[0].type == AstType.rule);
    assert(ast.children[0].data == "all");
    assert(ast.children[0].children.length == 1); // prereq only
    assert(ast.children[0].children[0].data == "main.o");

    assert(ast.children[1].type == AstType.rule);
    assert(ast.children[1].data == "clean");
    assert(ast.children[1].children.length == 1); // recipe only
}

/// Order-only prerequisites with pipe separator.
unittest
{
    auto ast = parse("target: normal | orderonly");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "target");
    assert(rule.children.length == 3, "should have normal, |, orderonly");
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "normal");
    assert(rule.children[1].type == AstType.prerequisite);
    assert(rule.children[1].data == "|");
    assert(rule.children[2].type == AstType.prerequisite);
    assert(rule.children[2].data == "orderonly");
}

/// Double-colon rule.
unittest
{
    auto ast = parse("target:: prereq");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "target::", "double-colon rule should encode ::");
    assert(rule.children.length == 1);
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "prereq");
}

/// Multiple target identifiers in a rule.
unittest
{
    auto ast = parse("target1 target2: prereq");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.type == AstType.rule);
    assert(rule.data == "target1 target2"); // all targets space-separated
}

/// Inline recipe via semicolon.
unittest
{
    auto ast = parse("target: prereq; echo building\n\tcc -o target prereq");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.data == "target");
    // prereq + inline recipe + recipe line = 3 children
    assert(rule.children.length == 3);
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "prereq");
    assert(rule.children[1].type == AstType.recipe_line);
    assert(rule.children[1].data == " echo building");
    assert(rule.children[2].type == AstType.recipe_line);
    assert(rule.children[2].data == "cc -o target prereq");
}

/// Recipe line with leading whitespace after tab (the lexer skips it).
unittest
{
    auto ast = parse("all:\n\t  cc -o all main.o");
    assert(ast.children.length == 1);
    auto rule = ast.children[0];
    assert(rule.children[0].type == AstType.recipe_line);
    // readRawLine preserves internal spaces
    assert(rule.children[0].data == "  cc -o all main.o");
}

/// Multiple recipe lines for a single rule.
unittest
{
    auto ast = parse("all: main.o\n\tcc -c main.c\n\tmv main.o build/");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.data == "all");
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "main.o");
    assert(rule.children[1].type == AstType.recipe_line);
    assert(rule.children[1].data == "cc -c main.c");
    assert(rule.children[2].type == AstType.recipe_line);
    assert(rule.children[2].data == "mv main.o build/");
}

/// Comments between recipe lines (they produce newline tokens).
unittest
{
    auto ast = parse("target:\n\tcmd1\n# comment\n\tcmd2");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.children.length == 2); // 2 recipes
    assert(rule.children[0].data == "cmd1");
    assert(rule.children[1].data == "cmd2");
}

/// Conditional block: ifdef with else.
unittest
{
    auto ast = parse("ifdef DEBUG\nCC = gcc -g\nelse\nCC = gcc\nendif");
    assert(ast.children.length == 1);

    auto dir = ast.children[0];
    assert(dir.type == AstType.directive);
    assert(dir.data == "ifdef DEBUG");

    // "then" branch: 1 child (the variable assignment)
    assert(dir.children.length >= 1);
    assert(dir.children[0].type == AstType.variable_assignment);
    assert(dir.children[0].data == "CC= gcc -g");

    // "else" branch
    assert(dir.children.length == 2);
    assert(dir.children[1].type == AstType.directive);
    assert(dir.children[1].data == "else");
    assert(dir.children[1].children.length == 1);
    assert(dir.children[1].children[0].type == AstType.variable_assignment);
    assert(dir.children[1].children[0].data == "CC= gcc");
}

/// Conditional block: ifndef without else.
unittest
{
    auto ast = parse("ifndef FOO\nBAR = baz\nendif");
    assert(ast.children.length == 1);

    auto dir = ast.children[0];
    assert(dir.type == AstType.directive);
    assert(dir.data == "ifndef FOO");
    assert(dir.children.length == 1);
    assert(dir.children[0].type == AstType.variable_assignment);
    assert(dir.children[0].data == "BAR= baz");
}

/// Conditional block: ifeq with paren syntax.
unittest
{
    auto ast = parse("ifeq ($(ARCH), x86)\nCC = gcc\nendif");
    assert(ast.children.length == 1);

    auto dir = ast.children[0];
    assert(dir.type == AstType.directive);
    assert(dir.data == "ifeq ($(ARCH), x86)");
}

/// Generic directives: include, define, export, vpath.
unittest
{
    {
        auto ast = parse("include foo.mk");
        assert(ast.children[0].type == AstType.directive);
        assert(ast.children[0].data == "include foo.mk");
    }
    {
        auto ast = parse("vpath %.h include");
        assert(ast.children[0].type == AstType.directive);
        assert(ast.children[0].data == "vpath %.h include");
    }
    {
        auto ast = parse("export FOO");
        assert(ast.children[0].type == AstType.directive);
        assert(ast.children[0].data == "export FOO");
    }
    {
        auto ast = parse("define mymacro\ncontent\nendef");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "mymacro=content");
    }
    {
        // Multi-line define with multiple body lines
        auto ast = parse("define CMD\n\t@echo hello\n\t@echo world\nendef");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "CMD=\t@echo hello\n\t@echo world");
    }
    {
        // define with empty body
        auto ast = parse("define EMPTY\nendef");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "EMPTY=");
    }
    {
        // endef embedded in body text does NOT terminate early
        auto ast = parse("define VAR\nline 1\nthis mentions endef inline\nendef");
        assert(ast.children[0].type == AstType.variable_assignment);
        assert(ast.children[0].data == "VAR=line 1\nthis mentions endef inline");
    }
}

/// Tab without preceding rule is an error.
unittest
{
    bool caught = false;
    try
    {
        parse("\torphan recipe");
    }
    catch (Exception e)
    {
        caught = true;
    }
    // Tab without preceding rule is now silently consumed (GNU Make compat:
    // tabs inside conditionals are just indentation, not recipe markers).
    assert(!caught, "tab without rule should be silently consumed");
}

/// Variable reference in prerequisite (preserved as raw text).
unittest
{
    auto ast = parse("all: $(OBJS) ${LIBS} $<");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.children.length == 3);
    assert(rule.children[0].type == AstType.prerequisite);
    assert(rule.children[0].data == "$(OBJS)");
    assert(rule.children[1].type == AstType.prerequisite);
    assert(rule.children[1].data == "${LIBS}");
    assert(rule.children[2].type == AstType.prerequisite);
    assert(rule.children[2].data == "$<");
}

/// Empty input produces empty rule_list.
unittest
{
    auto ast = parse("");
    assert(ast.type == AstType.rule_list);
    assert(ast.children.length == 0);
}

/// Input with only whitespace/blank lines.
unittest
{
    auto ast = parse("\n\n");
    assert(ast.type == AstType.rule_list);
    assert(ast.children.length == 0);
}

/// Mix of rules and variable assignments.
unittest
{
    auto input = "CC = gcc\n\nall: main.o\n\t$(CC) -o all main.o";
    auto ast = parse(input);
    assert(ast.children.length == 2);

    assert(ast.children[0].type == AstType.variable_assignment);
    assert(ast.children[0].data == "CC= gcc");

    assert(ast.children[1].type == AstType.rule);
    assert(ast.children[1].data == "all");
}

/// Backslash-newline continuation in recipe lines.
unittest
{
    auto ast = parse("all:\n\tcc -o all \\\n\t    main.o");
    assert(ast.children.length == 1);

    auto rule = ast.children[0];
    assert(rule.children.length == 1); // one recipe line (continuation joined)
    assert(rule.children[0].type == AstType.recipe_line);
    // readRawLine joins the continuation — the raw text is "cc -o all     main.o"
    // because the \ is consumed and the leading tab/whitespace on the
    // continuation line is kept
}

/// Conditional with nested rules.
unittest
{
    auto input = "ifdef BUILD_TESTS\ntest: test.o\n\tcc -o test test.o\nendif";
    auto ast = parse(input);
    assert(ast.children.length == 1);

    auto dir = ast.children[0];
    assert(dir.type == AstType.directive);
    assert(dir.children.length == 1);
    assert(dir.children[0].type == AstType.rule);
    assert(dir.children[0].data == "test");
}
