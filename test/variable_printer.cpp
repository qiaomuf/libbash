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
/// \file variable_printer.cpp
/// \author Mu Qiao
/// \brief a program to write variables in a script into standard output
///

#include <algorithm>
#include <iostream>
#include <map>

#include <boost/range/algorithm/for_each.hpp>
#include <gtest/gtest.h>

#include "libbash.h"

using namespace std;

int main(int argc, char** argv)
{
  if(argc != 2)
  {
    cerr<<"Please provide your script as an argument"<<endl;
    exit(EXIT_FAILURE);
  }

  unordered_map<string, string> variables;
  libbash::interpret(argv[1], variables);

  std::map<string, string> sorted(variables.begin(), variables.end());
  boost::for_each(sorted, [&](const std::pair<string,string>& pair){
    cout << pair.first << '=' << pair.second << endl;
  });

  return 0;
}