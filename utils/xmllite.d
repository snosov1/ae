﻿/**
 * Light read-only XML library
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.utils.xmllite;

import std.stream;
import std.string;
import std.ascii;
import std.exception;

// ************************************************************************

/// Stream-like type with bonus speed
struct StringStream
{
	string s;
	size_t position;

	this(string s) { this.s = s; }

	void read(out char c) { c = s[position++]; }
	void seekCur(sizediff_t offset) { position += offset; }
	@property size_t size() { return s.length; }
}

// ************************************************************************

enum XmlNodeType
{
	Root,
	Node,
	Comment,
	Meta,
	DocType,
	Text
}

class XmlNode
{
	string tag;
	string[string] attributes;
	XmlNode[] children;
	XmlNodeType type;
	ulong startPos, endPos;

	this(Stream        s) { parse(s); }
	this(StringStream* s) { parse(s); }

	private final void parse(S)(S s)
	{
		startPos = s.position;
		char c;
		do
			s.read(c);
		while (isWhite(c));

		if (c!='<')  // text node
		{
			type = XmlNodeType.Text;
			string text;
			while (c!='<')
			{
				// TODO: check for EOF
				text ~= c;
				s.read(c);
			}
			s.seekCur(-1); // rewind to '<'
			tag = decodeEntities(text);
			//tag = tag.strip();
		}
		else
		{
			s.read(c);
			if (c=='!')
			{
				s.read(c);
				if (c == '-') // comment
				{
					expect(s, '-');
					type = XmlNodeType.Comment;
					do
					{
						s.read(c);
						tag ~= c;
					} while (tag.length<3 || tag[$-3..$] != "-->");
					tag = tag[0..$-3];
				}
				else // doctype, etc.
				{
					type = XmlNodeType.DocType;
					while (c != '>')
					{
						tag ~= c;
						s.read(c);
					}
				}
			}
			else
			if (c=='?')
			{
				type = XmlNodeType.Meta;
				tag = readWord(s);
				if (tag.length==0) throw new Exception("Invalid tag");
				while (true)
				{
					skipWhitespace(s);
					if (peek(s)=='?')
						break;
					readAttribute(s);
				}
				s.read(c);
				expect(s, '>');
			}
			else
			if (c=='/')
				throw new Exception("Unexpected close tag");
			else
			{
				type = XmlNodeType.Node;
				tag = c~readWord(s);
				while (true)
				{
					skipWhitespace(s);
					c = peek(s);
					if (c=='>' || c=='/')
						break;
					readAttribute(s);
				}
				s.read(c);
				if (c=='>')
				{
					while (true)
					{
						skipWhitespace(s);
						if (peek(s)=='<' && peek(s, 2)=='/')
							break;
						try
							children ~= new XmlNode(s);
						catch (Exception e)
							throw new Exception("Error while processing child of "~tag, e);
					}
					expect(s, '<');
					expect(s, '/');
					foreach (tc; tag)
						expect(s, tc);
					expect(s, '>');
				}
				else
					expect(s, '>');
			}
		}
		endPos = s.position;
	}

	this(XmlNodeType type, string tag = null)
	{
		this.type = type;
		this.tag = tag;
	}

	XmlNode addAttribute(string name, string value)
	{
		attributes[name] = value;
		return this;
	}

	XmlNode addChild(XmlNode child)
	{
		children ~= child;
		return this;
	}

	override string toString()
	{
		string childrenText()
		{
			string result;
			foreach (child; children)
				result ~= child.toString();
			return result;
		}

		string attrText()
		{
			string result;
			foreach (key, value; attributes)
				result ~= ' ' ~ key ~ `="` ~ encodeEntities(value) ~ '"';
			return result;
		}

		switch(type)
		{
			case XmlNodeType.Root:
				return childrenText();
			case XmlNodeType.Node:
				return '<' ~ tag ~ attrText() ~ '>' ~ childrenText() ~ "</" ~ tag ~ '>';
			case XmlNodeType.Meta:
				assert(children.length == 0);
				return "<?" ~ tag ~ attrText() ~ "?>";
			case XmlNodeType.DocType:
				assert(children.length == 0);
				return "<!" ~ tag ~ attrText() ~ ">";
			case XmlNodeType.Text:
				return encodeEntities(tag);
			default:
				return null;
		}
	}

	string text()
	{
		switch(type)
		{
			case XmlNodeType.Text:
				return tag;
			case XmlNodeType.Node:
			case XmlNodeType.Root:
				string childrenText;
				foreach (child; children)
					childrenText ~= child.text();
				return childrenText;
			default:
				return null;
		}
	}

	final XmlNode findChild(string tag)
	{
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				return child;
		return null;
	}

	final XmlNode[] findChildren(string tag)
	{
		XmlNode[] result;
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				result ~= child;
		return result;
	}

	final XmlNode opIndex(string tag)
	{
		auto node = findChild(tag);
		if (node is null)
			throw new Exception("No such child: " ~ tag);
		return node;
	}

	final XmlNode opIndex(string tag, size_t index)
	{
		auto nodes = findChildren(tag);
		if (index >= nodes.length)
			throw new Exception(format("Can't get node with tag %s and index %d, there are only %d children with that tag", tag, index, nodes.length));
		return nodes[index];
	}

	final XmlNode opIndex(size_t index)
	{
		return children[index];
	}

	final @property size_t length() { return children.length; }

	int opApply(int delegate(ref XmlNode) dg)
	{
		int result = 0;

		for (int i = 0; i < children.length; i++)
		{
			result = dg(children[i]);
			if (result)
				break;
		}
		return result;
	}

	final @property XmlNode dup()
	{
		auto result = new XmlNode(type, tag);
		result.attributes = attributes.dup;
		result.children.length = children.length;
		foreach (i, child; children)
			result.children[i] = child.dup;
		return result;
	}

private:
	final void readAttribute(S)(S s)
	{
		string name = readWord(s);
		if (name.length==0) throw new Exception("Invalid attribute");
		skipWhitespace(s);
		expect(s, '=');
		skipWhitespace(s);
		char delim;
		s.read(delim);
		if (delim != '\'' && delim != '"')
			throw new Exception("Expected ' or \'");
		string value;
		while (true)
		{
			char c;
			s.read(c);
			if (c==delim) break;
			value ~= c;
		}
		attributes[name] = decodeEntities(value);
	}
}

class XmlDocument : XmlNode
{
	this()
	{
		super(XmlNodeType.Root);
		tag = "<Root>";
	}

	this(Stream        s) { this(); parse(s); }
	this(StringStream* s) { this(); parse(s); }

	final void parse(S)(S s)
	{
		skipWhitespace(s);
		while (s.position < s.size)
			try
			{
				children ~= new XmlNode(s);
				skipWhitespace(s);
			}
			catch (Exception e)
				throw new Exception(format("Error at %d", s.position), e);
	}
}

private:

char peek(S)(S s, int n=1)
{
	char c;
	for (int i=0; i<n; i++)
		s.read(c);
	s.seekCur(-n);
	return c;
}

void skipWhitespace(S)(S s)
{
	char c;
	do
	{
		if (s.position==s.size)
			return;
		s.read(c);
	}
	while (isWhite(c));
	s.seekCur(-1);
}

bool isWord(char c)
{
	return c=='-' || c=='_' || c==':' || isAlphaNum(c);
}

string readWord(S)(S s)
{
	char c;
	string result;
	while (true)
	{
		s.read(c);
		if (!isWord(c))
			break;
		result ~= c;
	}
	s.seekCur(-1);
	return result;
}

void expect(S)(S s, char c)
{
	char c2;
	s.read(c2);
	enforce(c==c2, "Expected " ~ c ~ ", got " ~ c2);
}

unittest
{
	enum xmlText =
		`<?xml version="1.0" encoding="UTF-8"?>`
		`<quotes>`
			`<quote author="Alan Perlis">`
				`When someone says, &quot;I want a programming language in which I need only say what I want done,&quot; give him a lollipop.`
			`</quote>`
		`</quotes>`;
	auto doc = new XmlDocument(new MemoryStream(xmlText.dup));
	assert(doc.toString() == xmlText);
	doc = new XmlDocument(new StringStream(xmlText));
	assert(doc.toString() == xmlText);
}

const dchar[string] entities;
/*const*/ string[dchar] entityNames;
static this()
{
	entities =
	[
		"quot"[]: '\&quot;'  ,
		"amp"   : '\&amp;'   ,
		"lt"    : '\&lt;'    ,
		"gt"    : '\&gt;'    ,
		"circ"  : '\&circ;'  ,
		"tilde" : '\&tilde;' ,
		"nbsp"  : '\&nbsp;'  ,
		"ensp"  : '\&ensp;'  ,
		"emsp"  : '\&emsp;'  ,
		"thinsp": '\&thinsp;',
		"ndash" : '\&ndash;' ,
		"mdash" : '\&mdash;' ,
		"lsquo" : '\&lsquo;' ,
		"rsquo" : '\&rsquo;' ,
		"sbquo" : '\&sbquo;' ,
		"ldquo" : '\&ldquo;' ,
		"rdquo" : '\&rdquo;' ,
		"bdquo" : '\&bdquo;' ,
		"dagger": '\&dagger;',
		"Dagger": '\&Dagger;',
		"permil": '\&permil;',
		"lsaquo": '\&lsaquo;',
		"rsaquo": '\&rsaquo;',
		"euro"  : '\&euro;'  ,
		"copy"  : '\&copy;'  ,
		"apos"  : '\''
	];
	foreach (name, c; entities)
		entityNames[c] = name;
}

import std.utf;
import std.c.stdio;

public string encodeEntities(string str)
{
	// TODO: optimize
	foreach_reverse (i, c; str)
		if (c=='<' || c=='>' || c=='"' || c=='\'' || c=='&')
			str = str[0..i] ~ '&' ~ entityNames[c] ~ ';' ~ str[i+1..$];
	return str;
}

public string encodeAllEntities(string str)
{
	// TODO: optimize
	foreach_reverse (i, dchar c; str)
	{
		auto name = c in entityNames;
		if (name)
			str = str[0..i] ~ '&' ~ *name ~ ';' ~ str[i+stride(str,i)..$];
	}
	return str;
}

import ae.utils.text;
import std.conv;

public string decodeEntities(string str)
{
	auto fragments = str.fastSplit('&');
	if (fragments.length < 1)
		return str;

	auto interleaved = new string[fragments.length*2 - 1];
	auto buffers = new char[4][fragments.length-1];
	interleaved[0] = fragments[0];

	foreach (n, fragment; fragments[1..$])
	{
		auto p = fragment.indexOf(';');
		enforce(p>0, "Invalid entity (unescaped ampersand?)");

		dchar c;
		if (fragment[0]=='#')
		{
			if (fragment[1]=='x')
				c = fromHex!uint(fragment[2..p]);
			else
				c = to!uint(fragment[1..p]);
		}
		else
			c = entities[fragment[0..p]];

		interleaved[1+n*2] = cast(string) buffers[n][0..std.utf.encode(buffers[n], c)];
		interleaved[2+n*2] = fragment[p+1..$];
	}

	return interleaved.join();
}

deprecated alias decodeEntities convertEntities;

unittest
{
	assert(encodeAllEntities("©,€") == "&copy;,&euro;");
	assert(decodeEntities("&copy;,&euro;") == "©,€");
}
