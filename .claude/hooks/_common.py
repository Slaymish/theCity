"""Shared helpers for the bundled hooks. Every hook reads its knobs from
config.json in this directory, so the scripts themselves stay untouched."""
import fnmatch
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")


def load_payload():
    """Hook input arrives as one JSON object on stdin."""
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, ValueError):
        return {}


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def repo_root(payload):
    return payload.get("cwd") or os.getcwd()


def rel(path, root):
    try:
        return os.path.relpath(path, root)
    except ValueError:
        return path


def matches_any(path, globs):
    """Glob match with the `**` conventions people actually write.

    fnmatch's `*` already spans `/`, so the only special case needed is a
    leading `**/`, which must also match a file sitting at the repo root.
    """
    path = path.replace(os.sep, "/").lstrip("./")
    base = os.path.basename(path)
    for pattern in globs or []:
        candidates = {pattern}
        if pattern.startswith("**/"):
            candidates.add(pattern[3:])
        if pattern.endswith("/**"):
            candidates.add(pattern[:-3])
            candidates.add(pattern[:-2] + "*")
        for candidate in candidates:
            if fnmatch.fnmatch(path, candidate) or fnmatch.fnmatch(base, candidate):
                return True
    return False


STATUS_PREFIX = re.compile(r"^\s*[ MADRCU?!]{1,2}\s+")


def changed_paths(root):
    """Working-tree paths from `git status`, one entry per untracked file.

    Note the leading status column is variable-width once output has been
    stripped, so it is removed by pattern rather than by a fixed slice.
    """
    code, out = run("git status --porcelain -uall", root, timeout=20)
    if code != 0:
        return []
    paths = []
    for line in out.splitlines():
        if not line.strip():
            continue
        path = STATUS_PREFIX.sub("", line)
        if " -> " in path:          # rename: keep the destination
            path = path.split(" -> ", 1)[1]
        paths.append(path.strip().strip('"'))
    return paths


def deny(reason):
    """PreToolUse deny. Exit 0 with JSON so the reason reaches Claude."""
    emit({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })


def add_context(event, text):
    emit({
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": text,
        }
    })


def emit(obj):
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()
    sys.exit(0)


def run(cmd, cwd, timeout=120):
    """Run a shell command, returning (exit_code, combined_output)."""
    try:
        proc = subprocess.run(
            cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ss: %s" % (timeout, cmd)
    except OSError as exc:
        return 127, str(exc)


def trim(text, limit=2000):
    """Hook output is capped at 10,000 characters; stay well under it."""
    if len(text) <= limit:
        return text
    head = text[: limit // 2]
    tail = text[-limit // 2:]
    return head + "\n...[trimmed]...\n" + tail
