"""Tell whether the recorded reply cites a file with a line.

usage: finding-location.py <record> <revision>...      (run at the repository root)

A citation is `<path>:<line>`. Its path is taken whole: the content of a code span that holds the
citation or ends right before the colon, otherwise the word before the colon without the brackets,
quotes and Markdown link text that open it. A name with spaces is therefore read inside a code span.

The path is a location when it names
- a file tracked in one of the revisions (the candidate and its base, so a deleted file counts),
  written from the repository root, after `./`, or by any spelling that leads into the worktree;
- or, outside the worktree, a file that exists, written absolute or with `../` (a finding in a
  consumer repository).
A directory, a submodule, a link address and a path to nothing name no file.
Exit 0 when a location is found, 10 when the reply holds none.
"""
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

OPENERS = "([{<\"'*`"
CLOSERS = "\"'*`"


def composed(text):
    # Git on macOS, a directory name and a reply can spell one name with composed or decomposed marks.
    return unicodedata.normalize("NFC", text)


root = composed(os.path.realpath(os.getcwd()))
tracked = set()
for revision in sys.argv[2:]:
    listing = subprocess.run(["git", "ls-tree", "-r", "-z", revision], capture_output=True, check=True).stdout
    for entry in listing.decode("utf-8", "surrogateescape").split("\0"):
        kind, _, name = entry.partition("\t")
        # A symlink is a blob; a submodule is a commit and holds no line of this review.
        if name and kind.split()[1] == "blob":
            tracked.add(composed(name))
line_number = re.compile(r":[1-9]")


def names_file(path):
    if not path or "://" in path or path.endswith("/"):
        return False
    if not os.path.isabs(path):
        path = os.path.normpath(path)
        if not path.startswith(".."):
            return composed(path) in tracked
    # The last component is kept as written: a tracked symlink is the entry, not its target.
    physical = composed(os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path)))
    if (physical + os.sep).startswith(root + os.sep):
        # Inside the worktree the trees decide, also for a file the candidate deleted.
        return physical[len(root) + 1:] in tracked
    return os.path.isfile(path)


def cited_paths(line, colon):
    ticks = [at for at, char in enumerate(line) if char == "`"]
    for opened, closed in zip(ticks[0::2], ticks[1::2]):
        if opened < colon < closed:
            return [line[opened + 1:colon]]
        if closed == colon - 1:
            return [line[opened + 1:closed]]
    word = line[max(line.rfind(" ", 0, colon), line.rfind("\t", 0, colon)) + 1:colon]
    paths = []
    # As written first: a quote can be the last character of a file name.
    for text in (word, word.rstrip(CLOSERS)):
        paths += [text, text.lstrip(OPENERS), text.rpartition("](")[2]]
    return paths


def has_location(line):
    return any(
        names_file(path)
        for match in line_number.finditer(line)
        for path in cited_paths(line, match.start())
    )


in_reply = False
with Path(sys.argv[1]).open(encoding="utf-8", errors="replace") as record:
    for line in record:
        if line.startswith("REPLY:"):
            in_reply = True
        elif in_reply and has_location(line.rstrip("\n")):
            sys.exit(0)
# Distinguish a well-formed reply with no location from a runtime/read failure.
sys.exit(10)
