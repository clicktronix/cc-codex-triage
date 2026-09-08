#!/usr/bin/env python3
"""Extract typed session events and observed usage, without guessing a dollar price."""
import json
from pathlib import Path
import sys
import uuid

stream, destination, model, effort = sys.argv[1:]
session = ''
metadata = dict(model_requested=model or 'configured-default',
                effort_requested=effort or 'configured-default', usage=None, cost_usd=None)
for line in Path(stream).read_text(errors='replace').splitlines():
    try:
        event = json.loads(line)
    except ValueError:
        continue  # stderr shares the stream on failure
    if not isinstance(event, dict):
        continue
    if event.get('type') == 'thread.started' and not session:
        try:
            session = str(uuid.UUID(event['thread_id']))
        except (KeyError, ValueError, TypeError, AttributeError):
            pass
    if event.get('type') == 'turn.completed' and isinstance(event.get('usage'), dict):
        metadata['usage'] = event['usage']
path = Path(destination)
temporary = path.with_name(path.name + '.tmp')
temporary.write_text(json.dumps(metadata, separators=(',', ':')) + '\n')
temporary.replace(path)
print(session)
