"""Tell whether the recorded reply cites a file of the reviewed trees with a line.

usage: finding-location.py <record> <revision>...

A location is `<path>:<line>` where `<path>` is a file tracked in one of the revisions (the
candidate and its base, so a deleted file counts), written from the repository root: bare, after
`./`, or after the worktree's absolute path. The reply is searched for the tracked paths
themselves, so quoting, brackets and spaces in a name need no rule of their own. A finding can
also sit in a consumer outside the worktree: there `<path>` is a file that exists, written absolute
or from the repository root with `../`. Such a spelling that leads back into the worktree counts
only for a tracked file. A directory, a path to nothing and `localhost:3000` name no file. Run at
the repository root.
Exit 0 when a location is found, 10 when the reply holds none.
"""
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path


def composed(text):
    # Git on macOS and a reply can spell one name with composed or decomposed marks.
    return unicodedata.normalize("NFC", text)


root = os.path.realpath(os.getcwd())
tracked = set()
for revision in sys.argv[2:]:
    listing = subprocess.run(["git", "ls-tree", "-r", "-z", revision], capture_output=True, check=True).stdout
    for entry in listing.decode("utf-8", "surrogateescape").split("\0"):
        kind, _, name = entry.partition("\t")
        # A symlink is a blob; a submodule is a commit and holds no line of this review.
        if name and kind.split()[1] == "blob":
            tracked.add(composed(name))
longest = max(map(len, tracked), default=0)
line_number = re.compile(r":[1-9]")


def begins_name(line, start):
    # `myapp.txt:1` does not cite `app.txt`, and `missing/app.txt:1` does not either.
    return not (start and (line[start - 1].isalnum() or line[start - 1] in "_.-/"))


def from_root(line, start):
    """Whether the tracked path at `start` is the whole cited path, written from the root."""
    if begins_name(line, start):
        return True
    if line.startswith("./", start - 2) and begins_name(line, start - 2):
        return True
    return any(
        line[at] == "/" and begins_name(line, at) and os.path.realpath(line[at:start]) == root
        for at in range(start - 1)
    )


def on_disk(path):
    if not os.path.isfile(path):
        return False
    physical = os.path.realpath(path)
    # Inside the worktree the trees decide: an ignored build file is no more a location by its
    # absolute path than by its relative one.
    if physical.startswith(root + os.sep):
        return composed(os.path.relpath(physical, root)) in tracked
    return True


def path_ends(text):
    for match in line_number.finditer(text):
        end = match.start()
        yield end
        # A quote can close before the line number: `app.txt`:1, "app.txt":1, **app.txt**:1. Tried
        # after the text as written, since a quote can also be the last character of a name.
        while end and text[end - 1] in "`\"'*":
            end -= 1
            yield end


def has_location(line):
    names = composed(line)
    for end in path_ends(names):
        for start in range(max(0, end - longest), end):
            if names[start:end] in tracked and from_root(names, start):
                return True
    # The disk is asked with the reply's own bytes: a file system can tell the two spellings apart.
    for end in path_ends(line):
        for start in range(end):
            if (line[start] == "/" or line.startswith("../", start)) and begins_name(line, start) \
                    and on_disk(line[start:end]):
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
