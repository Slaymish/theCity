#!/usr/bin/env python3
"""Stop — refuse to end the turn while the repo's own checks are failing.

This is the hook that changes outcomes rather than style. Without it, "done"
means "Claude believes it is done". With it, "done" means typecheck and tests
passed on the code as it now stands.

Three safeguards against wasting time:
  * stop_hook_active short-circuits the loop the second time round.
  * Nothing runs unless a watched file actually changed.
  * A fingerprint of the working tree is cached, so an unchanged tree is not
    re-verified on every stop.
"""
import hashlib
import json
import os
import sys

from _common import (HERE, changed_paths, load_config, load_payload,
                     matches_any, repo_root, run, trim)

STATE_PATH = os.path.join(HERE, ".stop-gate-state.json")


def main():
    payload = load_payload()

    # Second pass after a block: let Claude stop rather than loop forever.
    if payload.get("stop_hook_active"):
        return 0

    config = load_config()
    gate = config.get("stopGate") or {}
    if not gate.get("enabled"):
        return 0

    root = repo_root(payload)
    checks = gate.get("run", [])
    if not checks:
        return 0

    changed = changed_paths(root)
    watch = gate.get("watchPaths", ["*"])
    if not any(matches_any(path, watch) for path in changed):
        return 0

    fingerprint = _fingerprint(root, changed)
    if _already_passed(fingerprint):
        return 0

    commands = config.get("commands", {})
    failures = []
    for name in checks:
        cmd = commands.get(name)
        if not cmd:
            continue
        code, output = run(cmd, root, timeout=gate.get("timeout", 300))
        if code != 0:
            failures.append("$ %s\n%s" % (cmd, trim(output, 1200)))

    if failures:
        sys.stderr.write(
            "Stop blocked — the repo's checks are failing on your changes.\n"
            "Fix these, then finish:\n\n" + "\n\n".join(failures) + "\n"
        )
        return 2  # Exit 2 on a blocking event returns this to Claude.

    _record_pass(fingerprint)
    return 0


def _fingerprint(root, changed):
    code, diff = run("git diff HEAD", root, timeout=20)
    blob = (diff if code == 0 else "") + "\n".join(sorted(changed))
    for path in sorted(changed):
        full = os.path.join(root, path)
        if os.path.isfile(full):
            try:
                with open(full, "rb") as fh:
                    blob += hashlib.sha1(fh.read()).hexdigest()
            except OSError:
                pass
    return hashlib.sha1(blob.encode("utf-8", "replace")).hexdigest()


def _already_passed(fingerprint):
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            return json.load(fh).get("passed") == fingerprint
    except (OSError, json.JSONDecodeError):
        return False


def _record_pass(fingerprint):
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as fh:
            json.dump({"passed": fingerprint}, fh)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
