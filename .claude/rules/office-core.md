---
description: OfficeCore package, CLI stream handling and fixtures
paths:
  - "Packages/OfficeCore/**"
  - "fixtures/**"
---

# OfficeCore

- Pure logic with no UI imports: no SwiftUI, AppKit or RealityKit.
- Tests use Swift Testing and run against the recorded streams in `fixtures/`. `make test` runs them all. For one suite, run `swift test --filter <Suite>` inside `Packages/OfficeCore`.
- Fixtures are real CLI output (see `fixtures/README.md`), so don't hand-edit them. To get a new one, record a real run and add a row to the README table. `malformed.jsonl` is the only hand-made one.
- Stream facts the code depends on:
  - `AskUserQuestion` only appears with `--input-format stream-json --permission-prompt-tool stdio`, after an `initialize` control request.
  - Background subagents emit one `result` per turn, so a run ends when the process exits, not on `result`.
  - One API message arrives as several `assistant` events sharing a `message.id`. Dedupe usage by that id.
  - Closing stdin does not stop a turn. Cancel sends SIGINT, then SIGTERM, then SIGKILL.
