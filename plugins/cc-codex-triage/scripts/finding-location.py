"""Recognize a source location in the recorded reply, including deleted files.

usage: finding-location.py <record> [<revision>...]

A name that is a file in one of the revisions is a location, and one that is a directory there is
not. A name the trees do not know counts when it has a directory part, so a path in another
repository does; a bare one does not, so `localhost:3000`, `node:20` and `step:2` do not. Without
revisions there is no tree to ask: a directory part or a letter is enough.
"""
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

# The characters of real paths: `C++.md`, `app/(auth)/[id]/page.tsx`, `packages/@scope/x.ts`.
location = re.compile(r"([\w./@+()\[\]-]+|`[^`\n]+`):[1-9][0-9]*")
revisions = sys.argv[2:]


def kinds(name):
    return {
        subprocess.run(["git", "cat-file", "-t", f"{revision}:{name}"], capture_output=True,
                       text=True).stdout.strip()
        for revision in revisions
    }


def is_location(name):
    # Prose wraps a path in brackets, `(app.txt:1)` or `[app.txt](app.txt:1)`: the path may start
    # after any of them. What a tree knows decides before the shape of the name does.
    starts = [0] + [at + 1 for at, char in enumerate(name) if char in "(["]
    found = set().union(*(kinds(name[start:]) for start in starts if name[start:]))
    if "blob" in found:
        return True
    if "tree" in found:
        return False
    if "/" in name.strip("/"):
        return True
    return not revisions and any(c.isalpha() or c == "_" for c in name)


def has_location(line):
    # Python's \w excludes combining marks in decomposed Git filenames: match on a copy that
    # replaces each with one character, and read the name from the original by position.
    probe = line
    if not line.isascii():
        probe = "".join("_" if unicodedata.category(c).startswith("M") else c for c in line)
    for match in location.finditer(probe):
        if is_location(line[match.start(1):match.end(1)].strip("`")):
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
