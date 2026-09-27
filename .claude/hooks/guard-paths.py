#!/usr/bin/env python3
"""PreToolUse:Edit|Write|MultiEdit|NotebookEdit — refuse writes to paths that
must not be hand-edited: lockfiles, build output, vendored code, generated
clients, secrets. Permission rules can express this too, but a hook can read
the actual file_path and give a reason that tells Claude what to do instead."""
import sys

from _common import deny, load_config, load_payload, matches_any, rel, repo_root

WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

DEFAULT_PROTECTED = [
    "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb",
    "poetry.lock", "uv.lock", "Cargo.lock", "go.sum", "Gemfile.lock",
    ".env", ".env.*", "*.pem", "id_rsa", "id_ed25519",
    "dist/**", "build/**", "out/**", ".next/**", "node_modules/**",
    "vendor/**", "target/**", "coverage/**", "__pycache__/**",
    "*.min.js", "*.min.css", "*.generated.*", "*_pb2.py", "*.pb.go",
]

GUIDANCE = {
    "lock": "Lockfiles are generated. Change the manifest and re-run the "
            "package manager instead.",
    "build": "That is build output. Edit the source that produces it.",
    "secret": "That file holds secrets. Update the .example file and tell me "
              "what to set locally.",
    "generated": "That file is generated. Edit the schema or template it comes from.",
}


def classify(name):
    lowered = name.lower()
    if "lock" in lowered:
        return "lock"
    if lowered.startswith(".env") or lowered.endswith((".pem", ".key")) or "id_rsa" in lowered:
        return "secret"
    if any(seg in name for seg in ("dist/", "build/", "out/", ".next/", "node_modules/",
                                   "vendor/", "target/", "coverage/")):
        return "build"
    return "generated"


def main():
    payload = load_payload()
    if payload.get("tool_name") not in WRITE_TOOLS:
        return 0

    tool_input = payload.get("tool_input") or {}
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path:
        return 0

    root = repo_root(payload)
    relative = rel(path, root)
    config = load_config()
    protected = config.get("protectedPaths", DEFAULT_PROTECTED)

    if matches_any(relative, protected):
        deny(
            "Blocked by guard-paths: %s is protected. %s"
            % (relative, GUIDANCE[classify(relative)])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
