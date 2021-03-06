/**
 * Wrappers for the git command-line tools.
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

module ae.sys.git;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.string;
import std.typecons;
import std.utf;

import ae.sys.cmd;
import ae.sys.file;
import ae.utils.aa;
import ae.utils.text;

struct Repository
{
	string path;

	// TODO: replace this with using the std.process workDir parameter in 2.066
	string[] argsPrefix;

	this(string path)
	{
		path = path.absolutePath();
		enforce(path.exists, "Repository path does not exist");
		auto dotGit = path.buildPath(".git");
		if (dotGit.exists && dotGit.isFile)
			dotGit = path.buildPath(dotGit.readText().strip()[8..$]);
		//path = path.replace(`\`, `/`);
		this.path = path;
		this.argsPrefix = [`git`, `--work-tree=` ~ path, `--git-dir=` ~ dotGit];
	}

	invariant()
	{
		assert(argsPrefix.length, "Not initialized");
	}

	// Have just some primitives here.
	// Higher-level functionality can be added using UFCS.
	void   run  (string[] args...) { auto owd = pushd(workPath(args[0])); return .run  (argsPrefix ~ args); }
	string query(string[] args...) { auto owd = pushd(workPath(args[0])); return .query(argsPrefix ~ args); }
	bool   check(string[] args...) { auto owd = pushd(workPath(args[0])); return spawnProcess(argsPrefix ~ args).wait() == 0; }
	auto   pipe (string[] args...) { auto owd = pushd(workPath(args[0])); return pipeProcess(argsPrefix ~ args); }

	/// Certain git commands (notably, bisect) must
	/// be run in the repository's root directory.
	private string workPath(string cmd)
	{
		switch (cmd)
		{
			case "bisect":
			case "submodule":
				return path;
			default:
				return null;
		}
	}

	History getHistory()
	{
		History history;

		Commit* getCommit(Hash hash)
		{
			auto pcommit = hash in history.commits;
			return pcommit ? *pcommit : (history.commits[hash] = new Commit(history.numCommits++, hash));
		}

		Commit* commit;

		foreach (line; query([`log`, `--all`, `--pretty=raw`]).splitLines())
		{
			if (!line.length)
				continue;

			if (line.startsWith("commit "))
			{
				auto hash = line[7..$].toCommitHash();
				commit = getCommit(hash);
			}
			else
			if (line.startsWith("tree "))
				continue;
			else
			if (line.startsWith("parent "))
			{
				auto hash = line[7..$].toCommitHash();
				auto parent = getCommit(hash);
				commit.parents ~= parent;
				parent.children ~= commit;
			}
			else
			if (line.startsWith("author "))
				commit.author = line[7..$];
			else
			if (line.startsWith("committer "))
			{
				commit.committer = line[10..$];
				commit.time = line.split(" ")[$-2].to!int();
			}
			else
			if (line.startsWith("    "))
				commit.message ~= line[4..$];
			else
				//enforce(false, "Unknown line in git log: " ~ line);
				commit.message[$-1] ~= line;
		}

		foreach (line; query([`show-ref`, `--dereference`]).splitLines())
		{
			auto h = line[0..40].toCommitHash();
			if (h in history.commits)
				history.refs[line[41..$]] = h;
		}

		return history;
	}

	/// Run a batch cat-file query.
	GitObject[] getObjects(Hash[] hashes)
	{
		GitObject[] result;
		result.reserve(hashes.length);

		auto pipes = this.pipe(`cat-file`, `--batch`);
		foreach (n, hash; hashes)
		{
			pipes.stdin.writeln(hash.toString());
			pipes.stdin.flush();

			auto headerLine = pipes.stdout.readln().strip();
			auto header = headerLine.split(" ");
			enforce(header.length == 3, "Malformed header during cat-file: " ~ headerLine);
			enforce(header[0].toCommitHash() == hash, "Unexpected object during cat-file");

			GitObject obj;
			obj.hash = hash;
			obj.type = header[1];
			auto size = to!size_t(header[2]);
			auto data = new ubyte[size];
			auto read = pipes.stdout.rawRead(data);
			enforce(read.length == size, "Unexpected EOF during cat-file");
			obj.data = data.assumeUnique();

			char[1] lf;
			pipes.stdout.rawRead(lf[]);
			enforce(lf[0] == '\n', "Terminating newline expected");

			result ~= obj;
		}
		pipes.stdin.close();
		enforce(pipes.pid.wait() == 0, "git cat-file exited with failure");
		return result;
	}

	struct ObjectWriterImpl
	{
		ProcessPipes pipes;

		Hash write(in void[] data)
		{
			auto p = NamedPipe("ae-sys-git-writeObjects");
			pipes.stdin.writeln(p.fileName);
			pipes.stdin.flush();

			auto f = p.connect();
			f.rawWrite(data);
			f.flush();
			f.close();

			return pipes.stdout.readln().strip().toCommitHash();
		}

		~this()
		{
			pipes.stdin.close();
			enforce(pipes.pid.wait() == 0, "git hash-object exited with failure");
		}
	}
	alias ObjectWriter = RefCounted!ObjectWriterImpl;

	/// Spawn a hash-object process which can hash and write git objects on the fly.
	ObjectWriter createObjectWriter(string type)
	{
		auto pipes = this.pipe(`hash-object`, `-t`, type, `-w`, `--stdin-paths`);
		return ObjectWriter(pipes);
	}

	/// Batch-write the given objects to the database.
	/// The hashes are saved to the "hash" fields of the passed objects.
	void writeObjects(GitObject[] objects)
	{
		string[] allTypes = objects.map!(obj => obj.type).toSet().keys;
		foreach (type; allTypes)
		{
			auto writer = createObjectWriter(type);
			foreach (ref obj; objects)
				if (obj.type == type)
					obj.hash = writer.write(obj.data);
		}
	}
}

struct GitObject
{
	Hash hash;
	string type;
	immutable(ubyte)[] data;

	struct ParsedCommit
	{
		Hash tree;
		Hash[] parents;
		string author, committer; /// entire lines - name, email and date
		string[] message;
	}

	ParsedCommit parseCommit()
	{
		enforce(type == "commit", "Wrong object type");
		ParsedCommit result;
		auto lines = (cast(string)data).split('\n');
		foreach (n, line; lines)
		{
			if (line == "")
			{
				result.message = lines[n+1..$];
				break; // commit message begins
			}
			auto parts = line.findSplit(" ");
			auto field = parts[0];
			line = parts[2];
			switch (field)
			{
				case "tree":
					result.tree = line.toCommitHash();
					break;
				case "parent":
					result.parents ~= line.toCommitHash();
					break;
				case "author":
					result.author = line;
					break;
				case "committer":
					result.committer = line;
					break;
				default:
					throw new Exception("Unknown commit field: " ~ field);
			}
		}
		return result;
	}

	static GitObject createCommit(ParsedCommit commit)
	{
		auto s = "tree %s\n%-(parent %s\n%|%)author %s\ncommitter %s\n\n%-(%s\n%)".format(
				commit.tree.toString(),
				commit.parents.map!(ae.sys.git.toString),
				commit.author,
				commit.committer,
				commit.message,
			);
		return GitObject(Hash.init, "commit", cast(immutable(ubyte)[])s);
	}

	struct TreeEntry
	{
		uint mode;
		string name;
		Hash hash;
	}

	TreeEntry[] parseTree()
	{
		enforce(type == "tree", "Wrong object type");
		TreeEntry[] result;
		auto rem = data;
		while (rem.length)
		{
			auto si = rem.countUntil(' ');
			auto zi = rem.countUntil(0);
			auto ei = zi + 1 + Hash.sizeof;
			auto str = cast(string)rem[0..zi];
			enforce(0 < si && si < zi && ei <= rem.length, "Malformed tree entry:\n" ~ hexDump(rem));
			result ~= TreeEntry(str[0..si].to!uint(8), str[si+1..zi], cast(Hash)rem[zi+1..ei]); // https://issues.dlang.org/show_bug.cgi?id=13112
			rem = rem[ei..$];
		}
		return result;
	}

	static GitObject createTree(TreeEntry[] entries)
	{
		auto buf = appender!(ubyte[]);
		foreach (entry; entries)
		{
			buf.formattedWrite("%o %s\0", entry.mode, entry.name);
			buf.put(entry.hash[]);
		}
		return GitObject(Hash.init, "tree", buf.data.assumeUnique);
	}
}

struct History
{
	Commit*[Hash] commits;
	uint numCommits = 0;
	Hash[string] refs;
}

alias ubyte[20] Hash;

struct Commit
{
	uint id;
	Hash hash;
	uint time;
	string author, committer;
	string[] message;
	Commit*[] parents, children;
}

Hash toCommitHash(in char[] hash)
{
	enforce(hash.length == 40, "Bad hash length: " ~ hash);
	ubyte[20] result;
	foreach (i, ref b; result)
		b = to!ubyte(hash[i*2..i*2+2], 16);
	return result;
}

string toString(ref Hash hash)
{
	return format("%(%02x%)", hash[]);
}

unittest
{
	assert(toCommitHash("0123456789abcdef0123456789ABCDEF01234567") == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67]);
}

/// Tries to match the default destination of `git clone`.
string repositoryNameFromURL(string url)
{
	return url
		.split(":")[$-1]
		.split("/")[$-1]
		.chomp(".git");
}

unittest
{
	assert(repositoryNameFromURL("https://github.com/CyberShadow/ae.git") == "ae");
	assert(repositoryNameFromURL("git@example.com:ae.git") == "ae");
}
