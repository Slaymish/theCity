# The City

A macOS 26 app (SwiftUI + RealityKit) that shows Claude Code runs as a city of robot-staffed offices, driven by the `claude` CLI's stream-JSON output.

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
| Release | `/release` |

`TheCity.xcodeproj` is generated and gitignored. Change `project.yml`, never the project.

## Checking your work

- Offscreen renders are the reliable check. Wrap them in a 120 s timeout and downscale with `sips -Z 1000` before viewing:
  `build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity -render-preview out.png [-theme light|dark] [-workspace "$PWD/SampleWorkspace"] [-city | -building [-floor N] | -focus <room>]`
- `-route-test "<request>"` prints Reception's routing decision (on-device, free).
- `-parallel-test` spends real money. Ask first.
- For the live window, use `Tools/Dev/relaunch.sh <args>`. To quit, use `osascript -e 'tell application "TheCity" to quit'`.

## Layout

- `Packages/OfficeCore/`: stream parser, control protocol, reducer, process layer and agent catalogue, with no UI.
- `App/`: SwiftUI screens, RealityKit scenes (`World`, `CityScene`, `BuildingScene`, `OfficeScene`), stores, on-device routing, theme and brands.
- `Assets/Pipeline/`: Blender scripts that produce `App/Models`. `Assets/Vendor/` holds the KayKit submodules.
- `fixtures/`: recorded real CLI streams for tests and replay.
- `Tools/Dev/`: live-window helpers and the README reel script.

## Detail lives elsewhere

- App, theming and RealityKit traps: `.claude/rules/app.md`
- OfficeCore, CLI stream facts and fixtures: `.claude/rules/office-core.md`
- Blender, sounds and credits: `.claude/rules/assets.md`
