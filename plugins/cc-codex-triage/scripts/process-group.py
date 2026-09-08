#!/usr/bin/env python3
"""Run one reviewer in its own process group; forward cancellation to all children."""
import os
import signal
import subprocess
import sys
import time


def stop_group(process):
    def send(signum):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    send(signal.SIGTERM)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    send(signal.SIGKILL)
    process.wait(timeout=2)


def main():
    received = []
    watched = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, watched)
    try:
        for signum in watched:
            signal.signal(signum, lambda sig, frame: received.append(sig))
        process = subprocess.Popen(
            sys.argv[1:], start_new_session=True,
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, previous),
        )
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    while not received and process.poll() is None:
        time.sleep(0.05)
    # Also reap leftover tool commands when the reviewer itself exited first.
    stop_group(process)
    if received:
        return 128 + received[0]
    rc = process.wait()
    return 128 - rc if rc < 0 else rc


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f'process-group: could not complete reviewer cleanup: {error}', file=sys.stderr)
        sys.exit(125)
