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
tree grammar libbashWalker;

options
{
	language = C;
	tokenVocab = libbash;
	ASTLabelType = pANTLR3_BASE_TREE;
}

import libbashPattern;

@includes{

	#include <memory>
	#include <string>
	#include <vector>

	#include <boost/xpressive/xpressive.hpp>

	class interpreter;
	void set_interpreter(interpreter* w);

}

@postinclude{

	#include <fstream>
	#include <iostream>
	#include <sstream>

	#include <boost/format.hpp>
	#include <boost/algorithm/string/join.hpp>

	#include "builtins/builtin_exceptions.h"
	#include "core/bash_condition.h"
	#include "core/interpreter.h"
	#include "cppbash_builtin.h"

}

@members{

	static interpreter* walker = 0;

	void set_interpreter(interpreter* w)
	{
		walker = w;
	}

	namespace
	{
		void set_index(const std::string& name, unsigned& index, int value)
		{
			if(value < 0)
				throw libbash::illegal_argument_exception((boost::format("Array index is less than 0: \%s[\%d]") \% name \% value).str());
			index = value;
		}

		// skip to next tree
		void seek_to_next_tree(plibbashWalker ctx)
		{
			// Current depth of the tree we are traversing
			int depth = 1;

			// The beginning should always be ROOT DOWN ANY_TOKEN
			// So we start from LA(4)
			int index = 4;
			for(; depth != 0; ++index)
			{
				// Go one level done if we encounter DOWN
				if(LA(index) == DOWN)
					++depth;
				// Go one level up if we encounter UP. When depth==0, we finishe one node
				else if(LA(index) == UP)
					--depth;
			}

			// Seek to the correct offset and consume.
			SEEK(INDEX() + index - 2);
			CONSUME();
		}

		void skip_next_token_or_tree(plibbashWalker ctx)
		{
			if(LA(2) != DOWN)
				SEEK(INDEX() + 1);
			else
				seek_to_next_tree(ctx);
		}

		bool match(const std::string& target,
				   const boost::xpressive::sregex& pattern)
		{
		  return boost::xpressive::regex_match(target, pattern);
		}

		/// \brief parse the text value of a tree to long
		/// \param the target tree
		/// \return the parsed value
		long parse_integer(ANTLR3_BASE_TREE* tree)
		{
			return tree->getText(tree)->toInt32(tree->getText(tree));
		}

		/// \brief a helper function that get the string value
		///        of the given pANTLR3_BASE_TREE node.
		/// \param the target tree node
		/// \return the value of node->text
		std::string get_string(pANTLR3_BASE_TREE node)
		{
			pANTLR3_COMMON_TOKEN token = node->getToken(node);
			// The tree walker may send null pointer here, so return an empty
			// string if that's the case.
			if(!token->start)
				return "";
			// Use reinterpret_cast here because we have to cast C code.
			// The real type here is int64_t which is used as a pointer.
			// token->stop - token->start + 1 should be bigger than 0.
			return std::string(reinterpret_cast<const char *>(token->start),
							   boost::numeric_cast<unsigned>(token->stop - token->start + 1));
		}

		char get_char(pANTLR3_BASE_TREE node)
		{
			return *reinterpret_cast<const char *>(node->getToken(node)->start);
		}
	}
}

start: list EOF;

list: ^(LIST (logic_command_list)+);

variable_definitions
@declarations {
	bool local = false;
}
	:^(VARIABLE_DEFINITIONS (LOCAL { local = true; })? var_def[local]*);

name_base returns[std::string libbash_value]
	:NAME { $libbash_value = get_string($NAME); }
	|LETTER { $libbash_value = get_string($LETTER); }
	|'_' { $libbash_value="_"; };

name returns[std::string libbash_value, unsigned index]
@init {
	$index = 0;
}
	:^(libbash_name=name_base value=arithmetics) {
		set_index(libbash_name, $index, value);
		$libbash_value = libbash_name;
	}
	|libbash_name=name_base {
		$libbash_value = libbash_name;
	};

num returns[std::string libbash_value]
options{ k=1; }
	:DIGIT { $libbash_value = get_string($DIGIT); }
	|NUMBER { $libbash_value = get_string($NUMBER); };

var_def[bool local]
@declarations {
	std::map<unsigned, std::string> values;
	unsigned index = 0;
}
	:^(EQUALS name string_expr?) {
		if(local)
			walker->define_local($name.libbash_value, $string_expr.libbash_value, false, $name.index);
		else
			walker->set_value($name.libbash_value, $string_expr.libbash_value, $name.index);
	}
	|^(EQUALS libbash_name=name_base ^(ARRAY (
										(expr=string_expr
										|^(EQUALS value=arithmetics {
												set_index(libbash_name, index, value);
											} expr=string_expr))
										{ values[index++] = expr.libbash_value; })*
									 )){
		if(local)
			walker->define_local(libbash_name, values);
		else
			walker->define(libbash_name, values);
	};

string_expr returns[std::string libbash_value, bool quoted]
@init {
	$quoted = true;
	bool is_raw_string = true;
	std::vector<std::string> brace_expansion_base{""};
	std::vector<std::string> brace_expansion_elements;
}
@after {
	if(!is_raw_string && brace_expansion_base.size() > 1)
		throw libbash::unsupported_exception("We only support brace expansion in raw string for now");
	$libbash_value = boost::algorithm::join(brace_expansion_base, " ");
}
	:^(STRING (
		string_part {
			for(auto iter = brace_expansion_base.begin(); iter != brace_expansion_base.end(); ++iter)
				*iter += $string_part.libbash_value;
			$quoted = $string_part.quoted;
			if(is_raw_string)
				is_raw_string = $string_part.is_raw_string;
		}
		|(BRACE_EXP) => ^(BRACE_EXP brace_expansion[brace_expansion_elements]) {
			auto group_number = brace_expansion_elements.size();
			auto group_size = brace_expansion_base.size();
			std::vector<std::string> expanded_values;

			expanded_values.reserve(group_number * group_size);
			for(auto iter = brace_expansion_base.begin(); iter != brace_expansion_base.end(); ++iter)
				for(std::vector<std::string>::size_type i = 0u; i != group_number; ++i)
					expanded_values.push_back(*iter + brace_expansion_elements[i \% group_number]);

			brace_expansion_base.swap(expanded_values);
			brace_expansion_elements.clear();
		}
	)*);

brace_expansion[std::vector<std::string>& elements]
	:(string_expr{
		$elements.push_back($string_expr.libbash_value);
	})+;

string_part returns[std::string libbash_value, bool quoted, bool is_raw_string]
@init {
	$quoted = false;
	$is_raw_string = true;
}
	:(DOUBLE_QUOTED_STRING) =>
		^(DOUBLE_QUOTED_STRING (libbash_string=double_quoted_string {
									$libbash_value += libbash_string;
									$quoted = true;
								})*)
	|(SINGLE_QUOTED_STRING) => ^(SINGLE_QUOTED_STRING node=SINGLE_QUOTED_STRING_TOKEN) {
		pANTLR3_COMMON_TOKEN token = node->getToken(node);
		$libbash_value = std::string(reinterpret_cast<const char *>(token->start + 1),
									 boost::numeric_cast<unsigned>(token->stop - token->start - 1));
	}
	|(ARITHMETIC_EXPRESSION) =>
		^(ARITHMETIC_EXPRESSION value=arithmetics {
			$libbash_value = boost::lexical_cast<std::string>(value);
			$is_raw_string = false;
		})
	|(var_ref[false]) => libbash_string=var_ref[false] {
		$libbash_value = libbash_string;
		$is_raw_string = false;
	}
	|libbash_string=command_substitution {
		$libbash_value = libbash_string;
		$is_raw_string = false;
	}
	|(libbash_string=any_string {
		$libbash_value = libbash_string;
	});

bash_pattern[boost::xpressive::sregex& pattern, bool greedy]
	:	pattern_start[pattern, greedy, walker->get_additional_option("extglob")];

//double quoted string rule, allows expansions
double_quoted_string returns[std::string libbash_value]
	:(var_ref[true]) => libbash_string=var_ref[true] { $libbash_value = libbash_string; }
	|(ARITHMETIC_EXPRESSION) => ^(ARITHMETIC_EXPRESSION value=arithmetics) {
		$libbash_value = boost::lexical_cast<std::string>(value);
	}
	|libbash_string=command_substitution {
		$libbash_value = libbash_string;
	}
	|libbash_string=any_string { $libbash_value = libbash_string; };

any_string returns[std::string libbash_value]
@declarations {
	pANTLR3_BASE_TREE any_token;
}
	:any_token=. { $libbash_value = get_string(any_token); };

//Allowable variable names in the variable expansion
var_name returns[std::string libbash_value, unsigned index]
@init {
	$var_name.index = 0;
}
	:libbash_string=num {
		$index = boost::lexical_cast<unsigned>(libbash_string);
		$libbash_value = ($index != 0 ? "*" : "0");
	}
	|name {
		$libbash_value = $name.libbash_value;
		$index = $name.index;
	}
	|MINUS {
		$libbash_value = "-";
	};

array_name returns[std::string libbash_value]
	:^(ARRAY name (AT|TIMES)) { $libbash_value = $name.libbash_value; }
	// We do not care the difference between TIMES and AT for now
	|TIMES { $libbash_value = "*"; }
	|AT { $libbash_value = "*"; };

var_expansion returns[std::string libbash_value]
@declarations {
	using namespace boost::xpressive;
	sregex replace_pattern;
	bool greedy;
}
	:^(USE_DEFAULT_WHEN_UNSET_OR_NULL var_name libbash_word=word) {
		libbash_value = walker->do_default_expansion($var_name.libbash_value, libbash_word, $var_name.index);
	}
	|^(ASSIGN_DEFAULT_WHEN_UNSET_OR_NULL var_name libbash_word=word) {
		libbash_value = walker->do_assign_expansion($var_name.libbash_value, libbash_word, $var_name.index);
	}
	|^(USE_ALTERNATE_WHEN_UNSET_OR_NULL var_name libbash_word=word) {
		libbash_value = walker->do_alternate_expansion($var_name.libbash_value, libbash_word, $var_name.index);
	}
	|(^(OFFSET array_name arithmetics arithmetics)) => ^(OFFSET libbash_name=array_name offset=arithmetics length=arithmetics) {
		libbash_value = walker->do_subarray_expansion(libbash_name, offset, length);
	}
	|(^(OFFSET array_name offset=arithmetics)) => ^(OFFSET libbash_name=array_name offset=arithmetics) {
		libbash_value = walker->do_subarray_expansion(libbash_name, offset);
	}
	|(^(OFFSET var_name arithmetics arithmetics)) => ^(OFFSET var_name offset=arithmetics length=arithmetics) {
		libbash_value = walker->do_substring_expansion($var_name.libbash_value, offset, length, $var_name.index);
	}
	|^(OFFSET var_name offset=arithmetics) {
		libbash_value = walker->do_substring_expansion($var_name.libbash_value, offset, $var_name.index);
	}
	|^(POUND(
		var_name {
			libbash_value = boost::lexical_cast<std::string>(walker->get_length($var_name.libbash_value, $var_name.index));
		}
		|^(libbash_name=name_base ARRAY_SIZE) {
			libbash_value = boost::lexical_cast<std::string>(walker->get_array_length(libbash_name));
		}
	))
	|^(REPLACE_ALL var_name bash_pattern[replace_pattern, true] (replacement=string_expr)?) {
		libbash_value = walker->do_replace_expansion($var_name.libbash_value,
													 std::bind(&interpreter::replace_all,
															   std::placeholders::_1,
															   replace_pattern,
															   replacement.libbash_value),
													 $var_name.index);
	}
	|^(REPLACE_AT_END var_name bash_pattern[replace_pattern, true] (replacement=string_expr)?) {
		replace_pattern = sregex(replace_pattern >> eos);
		libbash_value = walker->do_replace_expansion($var_name.libbash_value,
													 std::bind(&interpreter::replace_all,
															   std::placeholders::_1,
															   replace_pattern,
															   replacement.libbash_value),
													 $var_name.index);
	}
	|^(LAZY_REMOVE_AT_END var_name bash_pattern[replace_pattern, false] (replacement=string_expr)?) {
		replace_pattern = sregex(bos >> (s1=*_) >> replace_pattern >> eos);
		libbash_value = walker->do_replace_expansion($var_name.libbash_value,
													 std::bind(&interpreter::lazy_remove_at_end,
															   std::placeholders::_1,
															   replace_pattern),
													 $var_name.index);
	}
	|^((REPLACE_AT_START { greedy = true; }|LAZY_REMOVE_AT_START { greedy = false; })
		var_name bash_pattern[replace_pattern, greedy] (replacement=string_expr)?) {
		replace_pattern = sregex(bos >> replace_pattern);
		libbash_value = walker->do_replace_expansion($var_name.libbash_value,
													 std::bind(&interpreter::replace_all,
															   std::placeholders::_1,
															   replace_pattern,
															   replacement.libbash_value),
													 $var_name.index);
	}
	|^(REPLACE_FIRST var_name bash_pattern[replace_pattern, true] (replacement=string_expr)?) {
		libbash_value = walker->do_replace_expansion($var_name.libbash_value,
													 std::bind(&interpreter::replace_first,
															   std::placeholders::_1,
															   replace_pattern,
															   replacement.libbash_value),
													 $var_name.index);
	};

word returns[std::string libbash_value]
	:(num) => libbash_string=num { $libbash_value = libbash_string; }
	|string_expr { $libbash_value = $string_expr.libbash_value; }
	|(VAR_REF) => libbash_string=var_ref[false] { $libbash_value = libbash_string; }
	|value=arithmetics { $libbash_value = boost::lexical_cast<std::string>(value); };

//variable reference
var_ref [bool double_quoted] returns[std::string libbash_value]
	:^(VAR_REF var_name) {
		$libbash_value = walker->resolve<std::string>($var_name.libbash_value, $var_name.index);
	}
	|^(VAR_REF libbash_string=array_name) { walker->get_all_elements_IFS_joined(libbash_string, $libbash_value); }
	|^(VAR_REF POUND) { $libbash_value = boost::lexical_cast<std::string>(walker->get_array_length("*")); }
	|^(VAR_REF QMARK) { $libbash_value = boost::lexical_cast<std::string>(walker->get_status()); }
	|^(VAR_REF BANG) { std::cerr << "$! has not been implemented yet" << std::endl; }
	|^(VAR_REF libbash_string=var_expansion) { $libbash_value = libbash_string; };

command
	:^(COMMAND command_atom);

command_atom
	:variable_definitions
	|function_definition
	|simple_command
	|compound_command;

simple_command
@declarations {
	std::vector<std::string> libbash_args;
}
	:string_expr (argument[libbash_args])* execute_command[$string_expr.libbash_value, libbash_args];

execute_command[const std::string& name, std::vector<std::string>& libbash_args]
@declarations {
	interpreter::local_scope current_scope(*walker);
	std::unique_ptr<std::ostream> out;
	std::unique_ptr<std::ostream> err;
	std::unique_ptr<std::istream> in;
	bool redirection = false;
}
	:var_def[true]* (redirect[out, err, in]{ redirection = true; })* {
		if(walker->has_function(name))
		{
			if(redirection)
				std::cerr << "We do not support redirection for function calls." << std::endl;
			ANTLR3_MARKER command_index = INDEX();
			try
			{
				ANTLR3_MARKER current_index = INDEX();
				// Calling functions may change current index
				walker->call(name, libbash_args);
				SEEK(current_index);
			}
			catch(return_exception& e)
			{
				SEEK(command_index);
			}
		}
		else if(cppbash_builtin::is_builtin(name))
		{
			walker->set_status(walker->execute_builtin(name, libbash_args, out.get(), err.get(), in.get()));
		}
		else if(name == "export")
		{
			std::cerr << "We do not support command env before the export builtin." << std::endl;
			walker->set_status(1);
		}
		else
		{
			walker->set_status(1);
			throw libbash::unsupported_exception(name + " is not supported yet");
		}
	}
	(BANG { walker->set_status(!walker->get_status()); })?;

redirect[std::unique_ptr<std::ostream>& out, std::unique_ptr<std::ostream>& err, std::unique_ptr<std::istream>& in]
	:^(REDIR LESS_THAN redirect_destination_input[in]) {
		std::cerr << "Redirection is not supported yet" << std::endl;
	}
	|^(REDIR GREATER_THAN redirect_destination_output[out])
	|^(REDIR DIGIT LESS_THAN redirect_destination_input[in]) {
		std::cerr << "Redirection is not supported yet" << std::endl;
	}
	|^(REDIR DIGIT GREATER_THAN redirect_destination_output[out]) {
		std::cerr << "Redirection is not supported yet" << std::endl;
	};

redirect_operator
	:LESS_THAN
	|GREATER_THAN
	|FILE_DESCRIPTOR DIGIT redirect_operator;

redirect_destination_output[std::unique_ptr<std::ostream>& out]
	:string_expr {
		out.reset(new std::ofstream($string_expr.libbash_value, std::ofstream::trunc));
	}
	|FILE_DESCRIPTOR DIGIT {
		std::cerr << "FILE_DESCRIPTOR redirection is not supported yet" << std::endl;
	}
	|FILE_DESCRIPTOR_MOVE DIGIT {
		std::cerr << "FILE_DESCRIPTOR_MOVE redirection is not supported yet" << std::endl;
	};

redirect_destination_input[std::unique_ptr<std::istream>& in]
	:string_expr {
		std::cerr << "Input redirection for file is not supported yet" << std::endl;
	}
	|FILE_DESCRIPTOR DIGIT {
		std::cerr << "FILE_DESCRIPTOR redirection is not supported yet" << std::endl;
	}
	|FILE_DESCRIPTOR_MOVE DIGIT {
		std::cerr << "FILE_DESCRIPTOR_MOVE redirection is not supported yet" << std::endl;
	};

argument[std::vector<std::string>& args]
	: string_expr {
		if($string_expr.quoted)
			args.push_back($string_expr.libbash_value);
		else
			walker->split_word($string_expr.libbash_value, args);
	};

logic_command_list
@declarations {
	bool logic_and;
}
	:command
	|^((LOGICAND { logic_and = true; } | LOGICOR { logic_and = false; }) command {
		if(logic_and ? !walker->get_status() : walker->get_status())
			command(ctx);
		else
			seek_to_next_tree(ctx);
	});

command_list: ^(LIST logic_command_list+);

compound_command
	: ^(CURRENT_SHELL command_list)
	| ^(COMPOUND_COND cond_expr)
	| ^(ARITHMETIC_EXPRESSION arithmetics)
	| for_expr
	| while_expr
	| if_expr
	| case_expr;

cond_expr
	:^(BUILTIN_TEST status=builtin_condition) { walker->set_status(!status); }
	|^(KEYWORD_TEST status=keyword_condition) { walker->set_status(!status); };

common_condition returns[bool status]
@declarations {
	boost::xpressive::sregex pattern;
}
	// -eq, -ne, -lt, -le, -gt, or -ge for arithmetic. -nt -ot -ef for files
	:^(NAME left_str=string_expr right_str=string_expr) {
		$status = internal::test_binary(get_string($NAME), left_str.libbash_value, right_str.libbash_value, *walker);
	}
	// -o for shell option,  -z -n for string, -abcdefghkprstuwxOGLSN for files
	|^(op=LETTER string_expr) {
		$status = internal::test_unary(get_char(op),
		                               $string_expr.libbash_value);
	}
	|^(EQUALS left_str=string_expr right_str=string_expr) {
		$status = left_str.libbash_value == right_str.libbash_value;
	}
	// Greedy is meaningless as we need to match the whole string
	|^(MATCH_PATTERN left_str=string_expr bash_pattern[pattern, false]) {
		$status = match(left_str.libbash_value, pattern);
	}
	|^(NOT_EQUALS left_str=string_expr right_str=string_expr) {
		$status = left_str.libbash_value != right_str.libbash_value;
	}
	// Greedy is meaningless as we need to match the whole string
	|^(NOT_MATCH_PATTERN left_str=string_expr bash_pattern[pattern, false]) {
		$status = !match(left_str.libbash_value, pattern);
	}
	|^(LESS_THAN left_str=string_expr right_str=string_expr) {
		$status = left_str.libbash_value < right_str.libbash_value;
	}
	|^(GREATER_THAN left_str=string_expr right_str=string_expr) {
		$status = left_str.libbash_value > right_str.libbash_value;
	}
	|string_expr { $status = (!$string_expr.libbash_value.empty()); };

keyword_condition returns[bool status]
	:^(LOGICOR l=keyword_condition r=keyword_condition) { $status= l || r; }
	|^(LOGICAND l=keyword_condition r=keyword_condition) { $status= l && r; }
	|^(NEGATION l=keyword_condition) { $status = !l; }
	|^(MATCH_REGULAR_EXPRESSION left_str=string_expr right_str=string_expr) {
		boost::xpressive::sregex re = boost::xpressive::sregex::compile(right_str.libbash_value);
		$status = boost::xpressive::regex_match(left_str.libbash_value, re);
	}
	|s=common_condition { $status = s; };

builtin_condition returns[bool status]
	:^(NEGATION l=builtin_condition) { $status = !l; }
	|^(BUILTIN_LOGIC o=LETTER l=builtin_condition r=builtin_condition) {
		char op = get_char(o);
		if(op == 'a')
			$status = l && r;
		else if(op == 'o')
			$status = l || r;
		else
			throw libbash::parse_exception(std::string("unrecognized operator in built-in test: ") + op);
	}
	|s=builtin_condition_primary { $status = s; };

builtin_condition_primary returns[bool status]
	:^(ESC_LT l=string_expr r=string_expr) { $status = (l.libbash_value < r.libbash_value); }
	|^(ESC_GT l=string_expr r=string_expr) { $status = (l.libbash_value > r.libbash_value); }
	|s=common_condition { $status = s; };

for_expr
@declarations {
	ANTLR3_MARKER commands_index;
	std::vector<std::string> splitted_values;

	ANTLR3_MARKER condition_index;
}
	:^(FOR libbash_string=name_base
		// Empty value as $@ is not supported currently
		(string_expr
		{
			// Word splitting happens here
			if($string_expr.quoted)
				splitted_values.push_back($string_expr.libbash_value);
			else
				walker->split_word($string_expr.libbash_value, splitted_values);
		}
		)+
		{
			if(splitted_values.empty())
			{
				//skip the body
				seek_to_next_tree(ctx);
				walker->set_status(0);
			}
			else
			{
				commands_index = INDEX();
				for(auto iter = splitted_values.begin(); iter != splitted_values.end(); ++iter)
				{
					walker->set_value(libbash_string, *iter);
					try
					{
						command_list(ctx);
					}
					catch(continue_exception& e)
					{
						e.rethrow_unless_correct_frame();
					}
					catch(break_exception& e)
					{
						e.rethrow_unless_correct_frame();
						SEEK(commands_index);
						break;
					}
					SEEK(commands_index);
				}
				seek_to_next_tree(ctx);
			}
		})
	|^(CFOR {
		// omit the first DOWN token for for_INIT
		SEEK(INDEX() + 1);

		if(LA(1) == FOR_INIT)
			for_initilization(ctx);

		condition_index = INDEX();
		bool has_condition = (LA(1) == FOR_COND);

		if(has_condition)
			seek_to_next_tree(ctx);
		// before the body
		seek_to_next_tree(ctx);
		bool has_modification = (LA(1) == FOR_MOD);
		ANTLR3_MARKER modification_index = INDEX();

		SEEK(condition_index);

		ANTLR3_MARKER command_index;
		while(!has_condition || for_condition(ctx))
		{
			command_index = INDEX();
			try
			{
				command_list(ctx);
			}
			catch(continue_exception& e)
			{
				e.rethrow_unless_correct_frame();

				if(has_modification)
				{
					SEEK(modification_index);
					for_modification(ctx);
				}
				SEEK(condition_index);
				continue;
			}
			catch(break_exception& e)
			{
				e.rethrow_unless_correct_frame();
				SEEK(command_index);
				break;
			}
			if(has_modification)
				for_modification(ctx);
			SEEK(condition_index);
		}

		// Get out of the loop
		// We are standing right after for_condition, we need to skip the command_list and optional for_modification
		seek_to_next_tree(ctx);
		if(LA(1) == FOR_MOD)
			seek_to_next_tree(ctx);

		// omit the last UP token
		SEEK(INDEX() + 1);
	});

for_initilization
	:^(FOR_INIT arithmetics);

for_condition returns[long libbash_value]
	:^(FOR_COND condition=arithmetics) { libbash_value = condition; };

for_modification
	:^(FOR_MOD arithmetics);

while_expr
@declarations {
	ANTLR3_MARKER condition_index;
	ANTLR3_MARKER command_index;
	bool negate;
}
	:^((WHILE { negate = false; } | UNTIL { negate = true; }) {
		// omit the first DOWN token
		SEEK(INDEX() + 1);

		condition_index = INDEX();
		while(true)
		{
			command_list(ctx);
			if(walker->get_status() == (negate? 0 : 1))
				break;

			command_index = INDEX();
			try
			{
				command_list(ctx);
			}
			catch(continue_exception& e)
			{
				e.rethrow_unless_correct_frame();
				SEEK(condition_index);
				continue;
			}
			catch(break_exception& e)
			{
				e.rethrow_unless_correct_frame();
				SEEK(command_index);
				break;
			}
			SEEK(condition_index);
		}
		// Skip the body and get out
		seek_to_next_tree(ctx);

		// omit the last UP token
		SEEK(INDEX() + 1);
	});

if_expr
@declarations {
	bool matched = false;
}
	:^(IF_STATEMENT {
		// omit the first DOWN token
		SEEK(INDEX() + 1);

		while(LA(1) == IF)
		{
			if(matched)
				seek_to_next_tree(ctx);
			else
				matched = elif_expr(ctx);
		}

		if(LA(1) == ELSE)
		{
			if(matched == false)
			{
				// omit the ELSE DOWN tokens
				SEEK(INDEX() + 2);

				command_list(ctx);

				// omit the last UP token
				SEEK(INDEX() + 1);
			}
			else
			{
				seek_to_next_tree(ctx);
			}
		}

		// omit the last UP token
		SEEK(INDEX() + 1);
	});

elif_expr returns[bool matched]
	:^(IF {
		// omit the first DOWN token
		SEEK(INDEX() + 1);

		command_list(ctx);
		if(walker->get_status() == 0)
		{
			$matched=true;
			command_list(ctx);
		}
		else
		{
			$matched=false;
			seek_to_next_tree(ctx);
		}

		// omit the last UP token
		SEEK(INDEX() + 1);
	});

case_expr
	:^(CASE libbash_string=word (matched=case_clause[libbash_string]{
		if(matched)
		{
			while(LA(1) == CASE_PATTERN)
				seek_to_next_tree(ctx);
		}
	})*);

case_clause[const std::string& target] returns[bool matched]
@declarations {
	std::vector<boost::xpressive::sregex> patterns;
}
	:^(CASE_PATTERN ( { patterns.push_back(boost::xpressive::sregex()); } bash_pattern[patterns.back(), true])+ {
		$matched = false;

		for(auto iter = patterns.begin(); iter != patterns.end(); ++iter)
		{
			if(match(target, *iter))
			{
				if(LA(1) == CASE_COMMAND)
				{
					// omit CASE_COMMAND
					SEEK(INDEX() + 1);
					command_list(ctx);
				}
				$matched = true;
				break;
			}
		}
		if(!$matched)
			seek_to_next_tree(ctx);
	});

command_substitution returns[std::string libbash_value]
@declarations {
	std::stringstream out;
}
	:^(COMMAND_SUB{ walker->set_output_stream(&out); } command_list) {
		walker->restore_output_stream();
		$libbash_value = out.str();
		walker->trim_trailing_eols($libbash_value);
	};

function_definition returns[int placeholder]
@declarations {
	std::string function_name;
}
	// We've already validated the function name in parser grammar so here we just use any_string to match the name.
	:^(FUNCTION ^(STRING (libbash_string=any_string { function_name += libbash_string; })+) {
		// Define the function with current index
		walker->define_function(function_name, INDEX());
		// Skip the AST for function body
		seek_to_next_tree(ctx);
	});

// Only used in arithmetic expansion
primary returns[std::string libbash_value, unsigned index]
	:(^(VAR_REF name)) => ^(VAR_REF name) {
		$libbash_value = $name.libbash_value;
		$index = $name.index;
	}
	|name {
		$libbash_value = $name.libbash_value;
		$index = $name.index;
	}
	// array[@] and array[*] is meaningless to arithmetic expansion so true/false are both ok.
	|^(VAR_REF libbash_string=var_ref[false]) {
		$libbash_value = libbash_string;
		$index = 0;
	};

// shell arithmetic
// http://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_06_04
arithmetics returns[long value]
	:^(LOGICOR l=arithmetics {
		if(l)
		{
			skip_next_token_or_tree(ctx);
			$value = 1;
		}
		else
		{
			$value = (arithmetics(ctx) != 0);
		}
	})
	|^(LOGICAND l=arithmetics {
		if(!l)
		{
			skip_next_token_or_tree(ctx);
			$value = 0;
		}
		else
		{
			$value = (arithmetics(ctx) != 0);
		}
	})
	|^(PIPE l=arithmetics r=arithmetics) { $value = l | r; }
	|^(CARET l=arithmetics r=arithmetics) { $value = l ^ r; }
	|^(AMP l=arithmetics r=arithmetics) { $value = l & r; }
	|^(LEQ l=arithmetics r=arithmetics) { $value = l <= r; }
	|^(GEQ l=arithmetics r=arithmetics) { $value = l >= r; }
	|^(LESS_THAN l=arithmetics r=arithmetics) { $value = l < r; }
	|^(GREATER_THAN l=arithmetics r=arithmetics) { $value = l > r; }
	|^(NOT_EQUALS l=arithmetics r=arithmetics) { $value = l != r; }
	|^(LSHIFT l=arithmetics r=arithmetics) { $value = l << r; }
	|^(RSHIFT l=arithmetics r=arithmetics) { $value = l >> r; }
	|^(PLUS l=arithmetics r=arithmetics) { $value = l + r; }
	|^(PLUS_SIGN l=arithmetics) { $value = l; }
	|^(MINUS l=arithmetics r=arithmetics) { $value = l - r; }
	|^(MINUS_SIGN l=arithmetics) { $value = -l; }
	|^(TIMES l=arithmetics r=arithmetics) { $value = l * r; }
	|^(SLASH l=arithmetics r=arithmetics) { $value = l / r; }
	|^(PCT l=arithmetics r=arithmetics) { $value = l \% r; }
	|^(EXP l=arithmetics r=arithmetics) {
		$value = 1;
		while(r--)
			$value *= l;
	}
	|^(BANG l=arithmetics) { $value = !l; }
	|^(TILDE l=arithmetics) { $value = ~l; }
	|^(ARITHMETIC_CONDITION cnd=arithmetics l=arithmetics r=arithmetics) {
		$value = (cnd ? l : r);
	}
	|primary {
		std::string primary_value(walker->resolve<std::string>($primary.libbash_value, $primary.index));
		$value = (primary_value.empty() ? 0 : walker->eval_arithmetic(primary_value));
	}
	|^(PRE_INCR primary) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) + 1,
								   $primary.index);
	}
	|^(PRE_DECR primary) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) - 1,
								   $primary.index);
	}
	|^(POST_INCR primary) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) + 1,
								   $primary.index);
		--$value;
	}
	|^(POST_DECR primary) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) - 1,
								   $primary.index);
		++$value;
	}
	|^(EQUALS primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value, l, $primary.index);
	}
	|^(MUL_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) * l,
								   $primary.index);
	}
	|^(DIVIDE_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) / l,
								   $primary.index);
	}
	|^(MOD_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) \% l,
								   $primary.index);
	}
	|^(PLUS_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) + l,
								   $primary.index);
	}
	|^(MINUS_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) - l,
								   $primary.index);
	}
	|^(LSHIFT_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) << l,
								   $primary.index);
	}
	|^(RSHIFT_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) >> l,
								   $primary.index);
	}
	|^(AND_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) & l,
								   $primary.index);
	}
	|^(XOR_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) ^ l,
								   $primary.index);
	}
	|^(OR_ASSIGN primary l=arithmetics) {
		$value = walker->set_value($primary.libbash_value,
		                           walker->resolve<long>($primary.libbash_value, $primary.index) | l,
								   $primary.index);
	}
	| NUMBER { $value = parse_integer($NUMBER);}
	| DIGIT { $value = parse_integer($DIGIT);}
	| ^(VAR_REF libbash_string = var_expansion) { $value = boost::lexical_cast<long>(libbash_string); }
	;
