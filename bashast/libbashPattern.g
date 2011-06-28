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
tree grammar libbashPattern;

options
{
	language = C;
	ASTLabelType = pANTLR3_BASE_TREE;
}

@includes{
	#include <string>
	#include <boost/xpressive/xpressive.hpp>
}

@postinclude{
	#include <boost/numeric/conversion/cast.hpp>
	#include "core/exceptions.h"
}

@members{
	// The method is used to append a pattern with another one. Because it's not allowed to append an empty pattern,
	// we need the argument 'do_append' to indicate whether the pattern is empty. 'do_append' will be set to true after
	// the first assignment.
	void append(boost::xpressive::sregex& pattern, const boost::xpressive::sregex& new_pattern, bool& do_append)
	{
		using namespace boost::xpressive;
		if(do_append)
		{
			pattern = sregex(pattern >> new_pattern);
		}
		else
		{
			pattern = new_pattern;
			do_append = true;
		}
	}

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
}

// This rule will be overridden.
string_part:{
	throw libbash::runtime_exception("The string_part rule isn't overridden");
};

pattern_start[boost::xpressive::sregex& pattern, bool greedy, bool extglob]
@declarations {
	using namespace boost::xpressive;
	bool do_append = false;
	sregex pattern_list;
	auto check_extglob = [&]() {
		if(!extglob)
			throw libbash::unsupported_exception("Entered extended pattern matching with extglob disabled");
	};
}
	:^(STRING (
		(EXTENDED_MATCH_AT_MOST_ONE) => ^(EXTENDED_MATCH_AT_MOST_ONE composite_pattern[pattern_list, $greedy]) {
			check_extglob();
			if($greedy)
				append($pattern, !sregex(pattern_list), do_append);
			else
				append($pattern, -!sregex(pattern_list), do_append);
		}
		|(EXTENDED_MATCH_ANY) => ^(EXTENDED_MATCH_ANY composite_pattern[pattern_list, $greedy]) {
			check_extglob();
			if($greedy)
				append($pattern, *sregex(pattern_list), do_append);
			else
				append($pattern, -*sregex(pattern_list), do_append);
		}
		|(EXTENDED_MATCH_AT_LEAST_ONE) => ^(EXTENDED_MATCH_AT_LEAST_ONE composite_pattern[pattern_list, $greedy]) {
			check_extglob();
			if($greedy)
				append($pattern, +sregex(pattern_list), do_append);
			else
				append($pattern, -+sregex(pattern_list), do_append);
		}
		// We don't have to do anything for the following rule
		|(EXTENDED_MATCH_EXACTLY_ONE) => ^(EXTENDED_MATCH_EXACTLY_ONE composite_pattern[pattern_list, $greedy]) {
			check_extglob();
			append($pattern, pattern_list, do_append);
		}
		|(EXTENDED_MATCH_NONE) => ^(EXTENDED_MATCH_NONE composite_pattern[pattern_list, $greedy]) {
			check_extglob();
			throw libbash::unsupported_exception("!(blah) is not supported for now");
		}
		|basic_pattern[$pattern, $greedy, do_append])+);

composite_pattern[boost::xpressive::sregex& pattern_list, bool greedy]
@declarations {
	using namespace boost::xpressive;
	bool do_append = false;
	bool do_sub_append = false;
	sregex sub_pattern;
}
	:(^(STRING
		(basic_pattern[sub_pattern, $greedy, do_sub_append]{
			if(do_append)
			{
				$pattern_list = sregex($pattern_list | sub_pattern);
			}
			else
			{
				$pattern_list = sub_pattern;
				do_append = true;
			}
			do_sub_append = false;
		})+
	))+;

basic_pattern[boost::xpressive::sregex& pattern, bool greedy, bool& do_append]
@declarations {
	using namespace boost::xpressive;
	bool negation;
	std::string pattern_str;
}
	:(MATCH_ALL) => MATCH_ALL {
		if($greedy)
			append($pattern, *_, do_append);
		else
			append($pattern, -*_, do_append);
	}
	|(MATCH_ONE) => MATCH_ONE {
		append($pattern, _, do_append);
	}
	|(MATCH_ANY_EXCEPT|MATCH_ANY) =>
	^((MATCH_ANY_EXCEPT { negation = true; } | MATCH_ANY { negation = false; })
	  ((CHARACTER_CLASS) => ^(CHARACTER_CLASS n=NAME) {
			std::string class_name = get_string(n);
			if(class_name == "word")
				pattern_str += "A-Za-z0-9_";
			else if(class_name == "ascii")
				pattern_str += "\\x00-\\x7F";
			else
				pattern_str += "[:" + class_name + ":]";
		}
		|s=string_part { pattern_str += s.libbash_value; })+) {

		if(negation)
			pattern_str = "[^" + pattern_str + "]";
		else
			pattern_str = "[" + pattern_str + "]";

		append($pattern, sregex::compile(pattern_str), do_append);
	}
	|string_part {
		append($pattern, as_xpr($string_part.libbash_value), do_append);
	};
