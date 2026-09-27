#!/usr/bin/env python3
"""SessionStart — inject the volatile facts about this checkout.

SessionStart stdout is added to the context Claude can see, so this is where
anything that goes stale belongs: branch, working-tree state, recent commits.
Keeping it here rather than in CLAUDE.md means CLAUDE.md stays a stable
document (good for prompt caching) and never lies about the current branch.

Deliberately capped at a few lines. A long brief is a tax on every session.
"""
import sys

from _common import changed_paths, load_config, load_payload, repo_root, run

MAX_CHANGED_LISTED = 12


def main():
    payload = load_payload()
    root = repo_root(payload)
    config = load_config()
    lines = []

    code, _ = run("git rev-parse --is-inside-work-tree", root, timeout=10)
    if code != 0:
        return 0  # Not a git repo; nothing worth saying.
    _, branch = run("git branch --show-current", root, timeout=10)
    branch = branch or "(detached)"

    changed = changed_paths(root)

    lines.append("Branch: %s (%d uncommitted file%s)"
                 % (branch, len(changed), "" if len(changed) == 1 else "s"))

    if changed:
        shown = changed[:MAX_CHANGED_LISTED]
        suffix = "" if len(changed) <= MAX_CHANGED_LISTED else \
            " (+%d more)" % (len(changed) - MAX_CHANGED_LISTED)
        lines.append("Uncommitted: " + ", ".join(shown) + suffix)

    code, log = run("git log --oneline -3", root, timeout=10)
    if code == 0 and log:
        lines.append("Recent: " + " | ".join(log.splitlines()))

    commands = config.get("commands", {})
    if commands:
        lines.append("Commands: " + "  ".join(
            "%s=`%s`" % (k, v) for k, v in commands.items() if v))

    note = config.get("sessionNote")
    if note:
        lines.append(note)

    print("<repo-state>\n" + "\n".join(lines) + "\n</repo-state>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
