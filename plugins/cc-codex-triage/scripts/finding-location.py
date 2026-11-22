"""Recognize a source location in the recorded reply, including deleted files."""
import re
import sys
import unicodedata
from pathlib import Path

location = re.compile(r"([\w./-]+|`[^`\n]+`):[1-9][0-9]*")


def has_location(line):
    # Python's \w excludes combining marks in decomposed Git filenames.
    if not line.isascii():
        line = "".join("_" if unicodedata.category(c).startswith("M") else c for c in line)
    for name in location.findall(line):
        if any(c.isalpha() or c == "_" for c in name) or "/" in name.strip("`/"):
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
