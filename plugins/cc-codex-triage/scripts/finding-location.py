"""Recognize a source location in the recorded reply, including deleted files.

usage: finding-location.py <record> [<revision>...]      (run at the repository root)

A name is read as a path from the repository root, also when it is written as an absolute path
inside the worktree. A name that is a file in one of the revisions is a location, and one that is a
directory there is not. A name the trees do not know counts when it has a directory part, so a
path in another repository does; a bare one does not, so `localhost:3000`, `node:20` and `step:2`
do not. Without revisions there is no tree to ask: a directory part or a letter is enough.
"""
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

location = re.compile(
    r"`([^`\n]+?):[1-9][0-9]*[^`\n]*`"       # a code span around the whole citation
    r"|`([^`\n]+)`:[1-9][0-9]*"              # a code span around the name
    # The characters of real paths: `C++.md`, `app/(auth)/[id]/page.tsx`, `packages/@scope/x.ts`.
    r"|([\w./@+()\[\]-]+):[1-9][0-9]*"
)
revisions = sys.argv[2:]
root = os.path.realpath(os.getcwd())


def from_root(name):
    if not os.path.isabs(name):
        return os.path.normpath(name)
    physical = os.path.realpath(name)
    return os.path.relpath(physical, root) if physical.startswith(root + os.sep) else name


def kinds(name):
    path = from_root(name)
    return {
        subprocess.run(["git", "cat-file", "-t", f"{revision}:{'' if path == '.' else path}"],
                       capture_output=True, text=True).stdout.strip()
        for revision in revisions
    }


def is_location(name):
    # The path may start inside the match: prose wraps it in brackets, `(app.txt:1)` or
    # `[app.txt](app.txt:1)`, and a code span can hold words before it. What a tree knows decides
    # before the shape of the name does.
    starts = [0] + [at + 1 for at, char in enumerate(name) if char in "([" or char.isspace()]
    found = set().union(*(kinds(name[start:]) for start in starts if name[start:].strip()))
    if "blob" in found:
        return True
    if "tree" in found:
        return False
    last = name.split()[-1]
    if "/" in last.strip("/"):
        return True
    return not revisions and any(c.isalpha() or c == "_" for c in last)


def has_location(line):
    # Python's \w excludes combining marks in decomposed Git filenames: match on a copy that
    # replaces each with one character, and read the name from the original by position.
    probe = line
    if not line.isascii():
        probe = "".join("_" if unicodedata.category(c).startswith("M") else c for c in line)
    for match in location.finditer(probe):
        group = match.lastindex
        name = line[match.start(group):match.end(group)].strip()
        if name and is_location(name):
            return True
    return False


in_reply = False
with Path(sys.argv[1]).open(encoding="utf-8", errors="replace") as record:
    for line in record:
        if line.startswith("REPLY:"):
            in_reply = True
        elif in_reply and has_location(line):
            sys.exit(0)
# Distinguish a well-formed reply with no location from a runtime/read failure.
sys.exit(10)
