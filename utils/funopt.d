﻿/**
 * Translate command-line parameters to a function signature,
 * generating --help text automatically.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.funopt;

import std.algorithm;
import std.array;
import std.conv;
import std.getopt;
import std.path;
import std.range;
import std.string;
import std.traits;
import std.typetuple;

import ae.utils.meta.misc;
import ae.utils.text;

private enum OptionType { switch_, option, parameter }

struct OptionImpl(OptionType type_, T_, string description_, char shorthand_, string placeholder_)
{
	enum type = type_;
	alias T = T_;
	enum description = description_;
	enum shorthand = shorthand_;
	enum placeholder = placeholder_;

	T value;
	alias value this;

	this(T value_)
	{
		value = value_;
	}
}

/// An on/off switch (e.g. --verbose). Does not have a value, other than its presence.
template Switch(string description=null, char shorthand=0)
{
	alias Switch = OptionImpl!(OptionType.switch_, bool, description, shorthand, null);
}

/// An option with a value (e.g. --tries N). The default placeholder depends on the type
/// (N for numbers, STR for strings).
template Option(T, string description=null, string placeholder=null, char shorthand=0)
{
	alias Option = OptionImpl!(OptionType.option, T, description, shorthand, placeholder);
}

/// An ordered parameter.
template Parameter(T, string description=null)
{
	alias Parameter = OptionImpl!(OptionType.parameter, T, description, 0, null);
}

private template OptionValueType(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		alias OptionValueType = T.T;
	else
		alias OptionValueType = T;
}

private OptionValueType!T* optionValue(T)(ref T option)
{
	static if (is(T == OptionImpl!Args, Args...))
		return &option.value;
	else
		return &option;
}

private template isParameter(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum isParameter = T.type == OptionType.parameter;
	else
	static if (is(T == bool))
		enum isParameter = false;
	else
		enum isParameter = true;
}

private template isOptionArray(Param)
{
	alias T = OptionValueType!Param;
	static if (is(T == string))
		enum isOptionArray = false;
	else
	static if (is(T U : U[]))
		enum isOptionArray = true;
	else
		enum isOptionArray = false;
}

private template optionShorthand(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum optionShorthand = T.shorthand;
	else
		enum char optionShorthand = 0;
}

private template optionDescription(T)
{
	static if (is(T == OptionImpl!Args, Args...))
		enum optionDescription = T.description;
	else
		enum string optionDescription = null;
}

private enum bool optionHasDescription(T) = optionDescription!T !is null;

private template optionPlaceholder(T)
{
	static if (is(T == OptionImpl!Args, Args...))
	{
		static if (T.placeholder.length)
			enum optionPlaceholder = T.placeholder;
		else
			enum optionPlaceholder = optionPlaceholder!(OptionValueType!T);
	}
	else
	static if (isOptionArray!T)
		enum optionPlaceholder = optionPlaceholder!(typeof(T.init[0]));
	else
	static if (is(T : real))
		enum optionPlaceholder = "N";
	else
	static if (is(T == string))
		enum optionPlaceholder = "STR";
	else
		enum optionPlaceholder = "X";
}

struct FunOptConfig
{
	std.getopt.config[] getoptConfig;
	string usageHeader, usageFooter;
}

/// Parse the given arguments according to FUN's parameters, and call FUN.
/// Throws GetOptException on errors.
auto funopt(alias FUN, FunOptConfig config = FunOptConfig.init)(string[] args)
{
	alias ParameterTypeTuple!FUN Params;
	Params values;
	enum names = [ParameterIdentifierTuple!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	foreach (i, defaultValue; defaults)
	{
		static if (!is(defaultValue == void))
		{
			//values[i] = defaultValue;
			// https://issues.dlang.org/show_bug.cgi?id=13252
			values[i] = cast(OptionValueType!(Params[i])) defaultValue;
		}
	}

	enum structFields =
		config.getoptConfig.length.iota.map!(n => "std.getopt.config config%d = std.getopt.config.%s;\n".format(n, config.getoptConfig[n])).join() ~
		Params.length.iota.map!(n => "string selector%d; OptionValueType!(Params[%d])* value%d;\n".format(n, n, n)).join();

	static struct GetOptArgs { mixin(structFields); }
	GetOptArgs getOptArgs;

	static string optionSelector(int i)()
	{
		string[] variants;
		auto shorthand = optionShorthand!(Params[i]);
		if (shorthand)
			variants ~= [shorthand];
		enum words = names[i].splitByCamelCase();
		variants ~= words.join().toLower();
		if (words.length > 1)
			variants ~= words.join("-").toLower();
		return variants.join("|");
	}

	foreach (i, ref value; values)
	{
		enum selector = optionSelector!i();
		mixin("getOptArgs.selector%d = selector;".format(i));
		mixin("getOptArgs.value%d = optionValue(values[%d]);".format(i, i));
	}

	auto origArgs = args;
	bool help;

	getopt(args,
		std.getopt.config.bundling,
		getOptArgs.tupleof,
		"h|help", &help,
	);

	void printUsage()
	{
		import std.stdio;
		stderr.writeln(config.usageHeader, getUsage!FUN(origArgs[0]), config.usageFooter);
	}

	if (help)
	{
		printUsage();
		return cast(ReturnType!FUN)0;
	}

	args = args[1..$];

	foreach (i, ref value; values)
	{
		alias T = Params[i];
		static if (isParameter!T)
		{
			static if (is(T == string[]))
			{
				values[i] = args;
				args = null;
			}
			else
			{
				if (args.length)
				{
					values[i] = to!T(args[0]);
					args = args[1..$];
				}
				else
				{
					static if (is(defaults[i] == void))
					{
						// If the first argument is mandatory,
						// and no arguments were given, print usage.
						if (origArgs.length == 1)
							printUsage();

						throw new GetOptException("No " ~ names[i] ~ " specified.");
					}
				}
			}
		}
	}

	if (args.length)
		throw new GetOptException("Extra parameters specified: %(%s %)".format(args));

	return FUN(values);
}

unittest
{
	void f1(bool verbose, Option!int tries, string filename)
	{
		assert(verbose);
		assert(tries == 5);
		assert(filename == "filename.ext");
	}
	funopt!f1(["program", "--verbose", "--tries", "5", "filename.ext"]);

	void f2(string a, Parameter!string b, string[] rest)
	{
		assert(a == "a");
		assert(b == "b");
		assert(rest == ["c", "d"]);
	}
	funopt!f2(["program", "a", "b", "c", "d"]);

	void f3(Option!(string[], null, "DIR", 'x') excludeDir)
	{
		assert(excludeDir == ["a", "b", "c"]);
	}
	funopt!f3(["program", "--excludedir", "a", "--exclude-dir", "b", "-x", "c"]);

	void f4(Option!string outputFile = "output.txt", string inputFile = "input.txt", string[] dataFiles = null)
	{
		assert(inputFile == "input.txt");
		assert(outputFile == "output.txt");
		assert(dataFiles == []);
	}
	funopt!f4(["program"]);

	void f5(string input = null)
	{
		assert(input is null);
	}
	funopt!f5(["program"]);
}

// ***************************************************************************

private string getProgramName(string program)
{
	auto programName = program.baseName();
	version(Windows)
	{
		programName = programName.toLower();
		if (programName.extension == ".exe")
			programName = programName.stripExtension();
	}

	return programName;
}

private string getUsage(alias FUN)(string program)
{
	auto programName = getProgramName(program);
	enum formatString = getUsageFormatString!FUN();
	return formatString.format(programName);
}

private string getUsageFormatString(alias FUN)()
{
	alias ParameterTypeTuple!FUN Params;
	enum names = [ParameterIdentifierTuple!FUN];
	alias defaults = ParameterDefaultValueTuple!FUN;

	string result = "Usage: %s";
	enum haveNonParameters = !allSatisfy!(isParameter, Params);
	enum haveDescriptions = anySatisfy!(optionHasDescription, Params);
	static if (haveNonParameters && haveDescriptions)
		result ~= " [OPTION]...";

	string getSwitchText(int i)()
	{
		alias Param = Params[i];
		string switchText = "--" ~ names[i].splitByCamelCase().join("-").toLower();
		static if (is(Param == OptionImpl!Args, Args...))
			static if (Param.type == OptionType.option)
				switchText ~= "=" ~ optionPlaceholder!Param;
		return switchText;
	}

	foreach (i, Param; Params)
		{
			static if (isParameter!Param)
			{
				result ~= " ";
				static if (!is(defaults[i] == void))
					result ~= "[";
				result ~= toUpper(names[i].splitByCamelCase().join("-"));
				static if (!is(defaults[i] == void))
					result ~= "]";
			}
			else
			{
				static if (optionHasDescription!Param)
					continue;
				else
					result ~= " [" ~ getSwitchText!i() ~ "]";
			}
			static if (isOptionArray!Param)
				result ~= "...";
		}

	result ~= "\n";

	static if (haveDescriptions)
	{
		enum haveShorthands = anySatisfy!(optionShorthand, Params);
		string[Params.length] selectors;
		size_t longestSelector;

		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
			{
				string switchText = getSwitchText!i();
				if (haveShorthands)
				{
					auto c = optionShorthand!Param;
					if (c)
						selectors[i] = "-%s, %s".format(c, switchText);
					else
						selectors[i] = "    %s".format(switchText);
				}
				else
					selectors[i] = switchText;
				longestSelector = max(longestSelector, selectors[i].length);
			}

		result ~= "\nOptions:\n";
		foreach (i, Param; Params)
			static if (optionHasDescription!Param)
			{
				result ~= wrap(
					optionDescription!Param,
					79,
					"  %-*s  ".format(longestSelector, selectors[i]),
					" ".replicate(2 + longestSelector + 2)
				);
			}
	}

	return result;
}

unittest
{
	void f1(
		Switch!("Enable verbose logging", 'v') verbose,
		Option!(int, "Number of tries") tries,
		Option!(int, "Seconds to wait each try", "SECS") timeout,
		string filename,
		string output = "default",
		string[] extraFiles = null
	)
	{}

	auto usage = getUsage!f1("program");
	assert(usage ==
"Usage: program [OPTION]... FILENAME [OUTPUT] [EXTRA-FILES]...

Options:
  -v, --verbose       Enable verbose logging
      --tries=N       Number of tries
      --timeout=SECS  Seconds to wait each try
", usage);

	void f2(
		bool verbose,
		Option!(string[]) extraFile,
		string filename,
		string output = "default"
	)
	{}

	usage = getUsage!f2("program");
	assert(usage ==
"Usage: program [--verbose] [--extra-file=STR]... FILENAME [OUTPUT]
", usage);
}

// ***************************************************************************

/// Dispatch the command line to a type's static methods, according to the
/// first parameter on the given command line (the "action").
/// String UDAs are used as usage documentation for generating --help output
/// (or when no action is specified).
auto funoptDispatch(alias Actions, FunOptConfig config = FunOptConfig.init)(string[] args)
{
	string program = args[0];

	auto fun(string action, string[] actionArguments = [])
	{
		foreach (m; __traits(allMembers, Actions))
		{
			enum name = m.toLower();
			if (name == action)
			{
				auto args = [getProgramName(program) ~ " " ~ action] ~ actionArguments;
				return funopt!(__traits(getMember, Actions, m), config)(args);
			}
		}

		throw new GetOptException("Unknown action: " ~ action);
	}

	enum actionList = genActionList!Actions();

	const FunOptConfig myConfig = (){
		auto c = config;
		c.getoptConfig ~= std.getopt.config.stopOnFirstNonOption;
		c.usageFooter = actionList ~ c.usageFooter;
		return c;
	}();
	return funopt!(fun, myConfig)(args);
}

private string genActionList(alias Actions)()
{
	string result = "\nActions:\n";

	size_t longestAction = 0;
	foreach (m; __traits(allMembers, Actions))
		static if (hasAttribute!(string, __traits(getMember, Actions, m)))
			longestAction = max(longestAction, m.length);

	foreach (m; __traits(allMembers, Actions))
		static if (hasAttribute!(string, __traits(getMember, Actions, m)))
		{
			enum name = m.toLower();
			result ~= wrap(
				//__traits(comment, __traits(getMember, Actions, m)), // https://github.com/D-Programming-Language/dmd/pull/3531
				getAttribute!(string, __traits(getMember, Actions, m)),
				79,
				"  %-*s  ".format(longestAction, name),
				" ".replicate(2 + longestAction + 2)
			);
		}

	return result;
}

unittest
{
	struct Actions
	{
		@(`Perform action f1`)
		static void f1(bool verbose) {}
	}

	funoptDispatch!Actions(["program", "f1", "--verbose"]);

	assert(genActionList!Actions() == "
Actions:
  f1  Perform action f1
");
}
