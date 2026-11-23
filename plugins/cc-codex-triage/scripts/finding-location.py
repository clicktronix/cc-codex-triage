"""Tell whether the recorded reply cites a file with a line.

usage: finding-location.py <record> <revision>...      (run at the repository root)

A citation is `<path>:<line>`. Its path is taken whole: the content of a code span that holds the
citation or ends right before the colon, otherwise the word before the colon without the brackets,
quotes and Markdown link text that open it. A name with spaces is therefore read inside a code span.

The path names a file when
- it is, as written, a file tracked in one of the revisions (the candidate and its base, so a
  deleted file counts), bare, after `./`, or after the worktree's own absolute path;
- or the file system resolves it to a file: inside the worktree that file must be tracked, outside
  it existing is enough (a finding in a consumer repository).
Nothing is normalized here: `..`, a symlinked directory and a trailing slash are the file system's
to resolve, so a path through a missing directory names nothing. A directory, a submodule, an
ignored file and a link address name no file.
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
backticks = re.compile(r"`+")


def names_file(path):
    if not path or "://" in path:
        return False
    written = path
    while written.startswith("./"):
        written = written[2:]
    if composed(written) in tracked:
        return True
    if os.path.isabs(path):
        # The worktree's own path in front of a tracked one, also for a file the candidate deleted.
        for at in range(1, len(path)):
            if path[at] == "/" and composed(path[at + 1:]) in tracked \
                    and os.path.isdir(path[:at]) and composed(os.path.realpath(path[:at])) == root:
                return True
    if not os.path.isfile(path):
        return False
    physical = composed(os.path.realpath(path))
    if (physical + os.sep).startswith(root + os.sep):
        return physical[len(root) + 1:] in tracked
    return True


def code_spans(line):
    """(content start, content end, end of the closing run) of each span: runs of equal length pair."""
    runs = [match.span() for match in backticks.finditer(line)]
    spans, at = [], 0
    while at < len(runs):
        size = runs[at][1] - runs[at][0]
        close = next((to for to in range(at + 1, len(runs)) if runs[to][1] - runs[to][0] == size), None)
        if close is None:
            at += 1
            continue
        spans.append((runs[at][1], runs[close][0], runs[close][1]))
        at = close + 1
    return spans


def cited_paths(line, colon):
    for start, end, closed in code_spans(line):
        if start <= colon < end:
            return [line[start:colon].strip()]
        if closed == colon:
            return [line[start:end].strip()]
    word = line[max(line.rfind(" ", 0, colon), line.rfind("\t", 0, colon)) + 1:colon]
    paths = []
    # As written first: a quote can be the last character of a file name.
    for text in (word, word.rstrip(CLOSERS)):
        paths += [text, text.lstrip(OPENERS), text.rpartition("](")[2].lstrip(OPENERS)]
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
