# The City

A macOS 26 app (SwiftUI + RealityKit) that shows Claude Code runs as a city of robot-staffed offices, driven by the `claude` CLI's stream-JSON output. An iOS 26 companion app follows and answers the city from a phone.

## Commands

| Task | Command |
|---|---|
| Regenerate the Xcode project from `project.yml` | `make project` |
| Build (Debug, into `build/`) | `make build` |
| Test (OfficeCore, against `fixtures/`) | `make test` |
| Test one suite | `cd Packages/OfficeCore && swift test --filter <Suite>` |
| Build and run against `SampleWorkspace/` | `make run` |
| Replay a recorded stream (no API calls) | `make replay` |
| Install to `/Applications` (do this after edits so a relaunch gets the new build) | `make install` |
| Build the iPhone companion for the simulator | `make companion` |
| Release | `/release` |

`TheCity.xcodeproj` is generated and gitignored. Change `project.yml`, never the project.

## Checking your work

- Offscreen renders are the reliable check. Wrap them in a 120 s timeout and downscale with `sips -Z 1000` before viewing:
  `build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity -render-preview out.png [-theme light|dark] [-workspace "$PWD/SampleWorkspace"] [-city | -building [-floor N] | -focus <room>]`
- `-route-test "<request>"` prints Reception's routing decision (on-device, free; add `-receptionist claude` to ask Haiku instead).
- `-graphics low|medium|high|ultra` forces a quality level, including in offscreen renders.
- `-parallel-test` spends real money. Ask first.
- For the live window, use `Tools/Dev/relaunch.sh <args>`, and `Tools/Dev/relaunch.sh --quit` to quit it. It runs this checkout's dev build on its own data (`build/data`), next to the installed app. Never quit `TheCity` by name, because that also quits the user's city and cancels its jobs, this one included.

## Layout

- `Packages/OfficeCore/`: stream parser, control protocol, reducer, process layer and agent catalogue, with no UI.
- `App/`: SwiftUI screens, RealityKit scenes (`World`, `CityScene`, `BuildingScene`, `OfficeScene`), stores, on-device routing, theme and brands.
- `Assets/Pipeline/`: Blender scripts that produce `App/Models`. `Assets/Vendor/` holds the KayKit submodules.
- `Companion/`: the iPhone app. It shares the scene files listed under `TheCityCompanion` in `project.yml`, so keep those free of Mac-only types (see `Docs/Companion.md`).
- `Shared/Link/`: the local network and iCloud links, compiled into both apps.
- `fixtures/`: recorded real CLI streams for tests and replay.
- `Tools/Dev/`: live-window helpers and the README reel script.

## Backlog

Bugs and to-dos are GitHub Issues on `Slaymish/theCity`, not files in the repo. Labels are listed in `CONTRIBUTING.md`.

- Read: `gh issue list [--label "area: office"]`, `gh issue view <n> --comments`.
- When you find a bug or follow-up that's out of scope for the task, offer to file it rather than leaving a TODO comment. Include the type, `area:` and `priority:` labels.
- Reference the issue in commits (`Fixes #n`) so it closes on merge.
- People with write access can comment `@claude` on an issue or PR to hand it to Claude in GitHub Actions (`.github/workflows/claude.yml`).
- The default `gh` account (`hamishburke`) can't label or close issues. Prefix those commands with `GH_TOKEN=$(gh auth token --user Slaymish)`.

## Detail lives elsewhere

- App, theming and RealityKit traps: `.claude/rules/app.md`
- OfficeCore, CLI stream facts and fixtures: `.claude/rules/office-core.md`
- Blender, sounds and credits: `.claude/rules/assets.md`
