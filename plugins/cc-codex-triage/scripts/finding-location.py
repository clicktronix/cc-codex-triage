"""Recognize a source location in the recorded reply, including deleted files.

usage: finding-location.py <record> [<revision>...]

A name with a directory part counts by its shape, so a path in another repository does too. A bare
name counts when it is a file at the root of one of the revisions; `localhost:3000`, `node:20` and
`step:2` are not. Without revisions there is no tree to ask and every alphabetic bare name counts.
"""
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

location = re.compile(r"([\w./-]+|`[^`\n]+`):[1-9][0-9]*")
revisions = sys.argv[2:]


def at_root(name):
    return any(
        subprocess.run(["git", "cat-file", "-e", f"{revision}:{name}"],
                       stderr=subprocess.DEVNULL).returncode == 0
        for revision in revisions
    )


def has_location(line):
    # Python's \w excludes combining marks in decomposed Git filenames: match on a copy that
    # replaces each with one character, and read the name from the original by position.
    probe = line
    if not line.isascii():
        probe = "".join("_" if unicodedata.category(c).startswith("M") else c for c in line)
    for match in location.finditer(probe):
        name = line[match.start(1):match.end(1)].strip("`")
        if "/" in name.strip("/"):
            return True
        if any(c.isalpha() or c == "_" for c in name) and (not revisions or at_root(name)):
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
