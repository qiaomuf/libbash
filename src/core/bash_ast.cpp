/*
   Please use git log for copyright holder and year information

   This file is part of libbash.

   libbash is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 2 of the License, or
   (at your option) any later version.

   libbash is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with libbash.  If not, see <http://www.gnu.org/licenses/>.
*/
///
/// \file bash_ast.cpp
/// \author Mu Qiao
/// \brief a wrapper class that helps interpret from istream and string
///

#include "core/interpreter_exception.h"
#include "libbashLexer.h"
#include "libbashParser.h"

#include "core/bash_ast.h"

bash_ast::bash_ast(const std::istream& source,
                   std::function<pANTLR3_BASE_TREE(plibbashParser)> p): parse(p)
{
  std::stringstream stream;
  stream << source.rdbuf();
  script = stream.str();
  init_parser(script);
}

bash_ast::~bash_ast()
{
  nodes->free(nodes);
  parser->free(parser);
  token_stream->free(token_stream);
  lexer->free(lexer);
  input->close(input);
}

void bash_ast::init_parser(const std::string& script)
{
  input = antlr3NewAsciiStringInPlaceStream(
    reinterpret_cast<pANTLR3_UINT8>(const_cast<char*>(script.c_str())),
    script.size(),
    NULL);

  if(input == NULL)
    throw interpreter_exception("Unable to open file " + script + " due to malloc() failure");

  lexer = libbashLexerNew(input);
  if ( lexer == NULL )
  {
    std::cerr << "Unable to create the lexer due to malloc() failure" << std::endl;
    error_count = 1;
    return;
  }

  token_stream = antlr3CommonTokenStreamSourceNew(
      ANTLR3_SIZE_HINT, lexer->pLexer->rec->state->tokSource);
  if (token_stream == NULL)
  {
    std::cerr << "Out of memory trying to allocate token stream" << std::endl;
    error_count = 1;
    return;
  }

  parser = libbashParserNew(token_stream);
  if (parser == NULL)
  {
    std::cerr << "Out of memory trying to allocate parser" << std::endl;
    error_count = 1;
    return;
  }

  ast = parse(parser);
  error_count = parser->pParser->rec->getNumberOfSyntaxErrors(parser->pParser->rec);
  nodes = antlr3CommonTreeNodeStreamNewTree(ast, ANTLR3_SIZE_HINT);
}

std::string bash_ast::get_dot_graph()
{
  pANTLR3_STRING graph = nodes->adaptor->makeDot(nodes->adaptor, ast);
  return std::string(reinterpret_cast<char*>(graph->chars));
}

std::string bash_ast::get_string_tree()
{
  return std::string(reinterpret_cast<char*>(ast->toStringTree(ast)->chars));
}

namespace
{
  void print_line_counter(std::stringstream& result,
                          pANTLR3_COMMON_TOKEN token,
                          int& line_counter,
                          int pos)
  {
    char* text = reinterpret_cast<char*>(token->getText(token)->chars);
    for(int i = pos; text[i] == '\n'; ++i)
      result << '\n' << line_counter++ << "\t";
  }
}

std::string bash_ast::get_tokens(std::function<std::string(ANTLR3_INT32)> token_map)
{
  std::stringstream result;
  int line_counter = 1;

  // output line number for the first line
  result << line_counter++ << "\t";

  pANTLR3_VECTOR token_list = token_stream->getTokens(token_stream);
  unsigned token_size = token_list->size(token_list);

  for(unsigned i = 0; i != token_size; ++i)
  {
    pANTLR3_COMMON_TOKEN token = reinterpret_cast<pANTLR3_COMMON_TOKEN>
      (token_list->get(token_list, i));
    std::string tokenName = token_map(token->getType(token));

    if(tokenName != "EOL" && tokenName != "COMMENT" && tokenName != "CONTINUE_LINE")
    {
      result << tokenName << " ";
    }
    // Output \n and line number before each COMMENT token for better readability
    else if(tokenName == "COMMENT")
    {
      print_line_counter(result, token, line_counter, 0);
      result << tokenName;
    }
    // Output \n and line number after each CONTINUE_LINE/EOL token for better readability
    // omit the last \n and line number
    else if(i + 1 != token_size)
    {
      result << tokenName;
      print_line_counter(result, token, line_counter, tokenName == "CONTINUE_LINE"? 1 : 0);
    }
  }

  return result.str();
}

void bash_ast::walker_start(plibbashWalker tree_parser)
{
  tree_parser->start(tree_parser);
}

int bash_ast::walker_arithmetics(plibbashWalker tree_parser)
{
  return tree_parser->arithmetics(tree_parser);
}

pANTLR3_BASE_TREE bash_ast::parser_start(plibbashParser parser)
{
  return parser->start(parser).tree;
}

pANTLR3_BASE_TREE bash_ast::parser_arithmetics(plibbashParser parser)
{
  return parser->arithmetics(parser).tree;
}


