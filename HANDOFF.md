# Handoff: The Office

For the next Claude Code session (the claude-work account). Written 27 September 2026 by the claude-personal session that built everything so far. Read this, then `README.md`, then `Docs/Reviews/game-review.md`.

The owner's global rules in `~/.claude-shared` apply (UK English, colour tokens only and no opacity modifiers, ask before any unapproved size/spacing/timing/colour, no auto-commits, comment policy). This folder is **not a git repo**; don't `git init` or commit without being asked.

## State right now

Updated 27 September 2026 by the claude-work session, which worked through the whole approved queue (items 1–10 of `Docs/Reviews/game-review.md`, listed in the report below) overnight without the owner available.

- `make build` succeeds with no warnings; `make test` passes 46 tests. Every item was checked with offscreen renders (see "Checking your work" for the new preview flags). The fresh build was launched live, ran for 25 s without a crash, and quit cleanly. Nothing was clicked through in the live window.
- An instance of The Office that an earlier session left running was quit during the smoke test (`open` brought it forward, then `osascript … quit`).

### Done in this pass (queue items)

1. Elbow rig (`robot.py`, `Worker`). The "white brick" in the review's close-ups was actually the desk clock (`OfficeScene.swift`, `clockBody`), whose face points away from the focus camera. It's still there: **raise with the owner**.
2. `grass` token (optional in `Brand.Tokens`, defaulting to The Office's values), grass disc out to the horizon, a two-row tree ring (`Assets/Pipeline/tree.py`), and a furnished lobby the size of the tower: back and left walls with a doorway, a lift core with a floor-button panel, a couch, a lamp, plants, and the receptionist facing out from behind the desk. Only one storey's sun is lit in the building view (three suns were overexposing the ground).
3. `DeskCard` (360 pt) pinned beside the robot's projected head: questions reuse `QuestionFields`/`OptionButton`; approvals are a permit slip with Allow / Always allow in <folder> / Deny stamps (`Haptics.stamp()`, stamp overlay, then the call). The camera focuses on the asking robot and returns afterwards. "N more waiting ›" cycles. The panel's Needs you list keeps working without shortcuts (the desk card owns ⌘1–9/⌘↩/⌘⌫). A folder flies back to the robot when the hand goes down.
4. Job ticket (perforated `TicketShape`), budget `RingGauge` in the counter, `StepBar` staff strip while running, panel hidden by default behind ⌘\, the Room inspector as a card beside the selected desk, "Delivered" card title, the manager walks the folder to the outbox (`Worker.walk`), and the tray keeps 5 jobs.
5. `World` (`App/World.swift`) and `WorldView` (`CityViews.swift`) replace `CityView`/`BuildingView`: one RealityView. Entering scales the city around the lot (`CameraRig.frame` maps a rig's space to the world), hands the camera over at an identical pose, sinks the façade and raises the tower (0.6 s). City buildings between the camera and the tower are hidden while inside.
6. Title screen (`TitleHUD`) over the city with a "For sale" lot, cones and a waving receptionist, slowly orbiting. Break ground raises the building (1.2 s, 5% overshoot, thunk and bell) and then enters it. `CityStore.visit` tracks last visits; `SinceYouLeftNote` at Reception; parcels on doorsteps. The journal now stores `buildingID`/`floorID`.
7. Cars drive the outer ring (keeping left), labels only on hover ("Empty lot", "2 floors · all quiet"), a hand balloon replaces the beacon, and working buildings get a `lamp` glow (a point light: the KayKit windows are texture, so real lit windows would need an atlas edit). Folder anticipation, squash and quarter turn; head bob on face change; hop on ★; idle strolls with a stretch (one robot at a time, cancelled by any event); daylight follows the clock (08:00–18:00); 2° pitch settle on focus. All behind Reduce Motion.
8. `Sound.swift` with Kenney CC0 cues (`App/Sounds`, credits alongside) for handoff, hand raised (a different ping when that floor isn't the one you're looking at), stamps, delivery, lift ding, ground-breaking and the lights-on ticks, plus a shared typing loop; volume slider in Settings. No outdoor or room ambience yet.
9. The Reception composer moves beside the receptionist when focused, the camera goes to the desk, the receptionist types while routing, then points while the matched floor's lift button lights (or scaffolding appears on the roof for a new floor). Hiring rows are ID badges in a grid (drag, context menu and VoiceOver actions kept).
10. Framed cards for the floor's last 12 completed jobs on the back wall, a Records binder beyond 12, and a trophy on the manager's desk of the floor holding the building's fastest job. The plant-growth idea from P2-1 wasn't done.

### Values chosen in this pass, not approved (ask the owner)

- Arm segments 0.15 / 0.14 m, elbow at 0.52; idle elbow 0; carry pose shoulder −1.0, elbow −0.6; stretch pose both arms −2.75.
- Tree scale 3.2–4.4, ring 1 m and 2.3 m outside the outer road; grass disc radius 400 m; camera far plane 6000.
- Lobby: sized to the tower footprint; lift core 3.6 × 5.2 × 1.6 m; lift doors 0.88 × 3 m in `tray`; panel in `robot` with `muted` buttons (lit ones `lamp`, emissive); couch/lamp/plant positions; lobby camera (distance 13, pitch 0.28, yaw 0.3) and lift framing (distance 20, pitch 0.14).
- Desk card: 40 pt right of the head, 20 pt margins; stamp overlay (`titleLarge`, 4 pt border, −12°, spring 0.18 s, then 350 ms before sending); "Allowed" in `text`, "Denied" in `error`.
- Ticket notch 3 pt; badge face 52 × 38 pt; budget ring reuses the usage thresholds.
- Walk speed 1.8 m/s; aisle z 2.3; drop hop 0.5 m. Strolls every 18–35 s, 4 s stretch.
- City scale for a building = tower width ÷ façade width; the scaled city sits 0.3 m below the lobby floor.
- Empty-lot pad in `floor`, sign at 0.28 scale, cones in `primaryFill`; greeter robot at 0.42 scale; title orbit 0.05 rad/s, title camera distance 9, pitch 0.42.
- Car speed 0.5 m/s; balloon radius 0.14 in `manager` with a `text` string; working glow 5000 (light) / 9000 (dark) at 2.2 m.
- Head bob 0.03 m over 0.1 s; hop duration 0.35 s; daylight swing ±60° with elevation dropping 45% at the ends.
- Sound: every cue choice, volumes (0.35–1), the typing loop at 12%, default volume 70%.
- Job cards 220 × 140 pt at 0.2 scale, 1.05 m apart, 0.72 m up the back wall; trophy in `folder` on a `desk` base.
- Reception composer 60 pt right of the receptionist's head.

### Loose ends to raise with the owner

- The desk clock that reads as a brick in close-ups (see item 1).
- `~/Library/Application Support/The Office/city.json` has a floor "Write a file hello.txt containing" (Build team) and `SampleWorkspace/hello.txt`. They came from a window the previous session launched with `-request` prefilled; someone clicked Hire staff and Open the office. Ask before deleting either.
- `.claude/settings.local.json` in the repo root predates this work; leave it.
- Alphero brand: still needs Alphero's department colours (only `#3D2051` is known) and a dark theme. Noted in `App/Brands/alphero/brand.json`.
- Values from earlier sessions still never approved: scene sizes (room spacing 7 m, walls 5.2 m, sill 1.3 m, window top 4.2 m, storey 6.4 m, city grid 2 m), 26° lens, camera smoothing 0.45–0.5 s, billboard 105 px/m, flags at half scale, face glyph sizes 92/132 pt, gauge rings 22 pt with amber ≥70% and red ≥90%, hover offsets, icon squircle inset 100/1024 and radius 22.5%.
- Not verified with real input: the whole live flow (title → break ground → building → reception → floor → answering at the desk), hover labels, the ⌘\ shortcut, drag on badges, and whether the sounds are mixed at sensible levels.

## How the code fits together

- `Packages/OfficeCore`: pure logic, with no UI. Stream parser, `OfficeReducer` (wire events → `OfficeEvent`s), control protocol (questions and approvals over stdin), `ClaudeProcess`, `Kit`/`KitLoader` (skills and MCP inventory via an invalid-model run that costs nothing), `AgentCatalogue`. Tests run against `fixtures/` (see `fixtures/README.md`).
- `App/CityStore.swift`: persisted buildings and floors, one `RunController` session per floor, routing (`Route`), the job journal.
- `App/RunController.swift`: one floor's session. It owns its `OfficeScene`, runs the CLI, and handles hiring, readiness, answers and the journal.
- Scenes:
  - `World` hosts `CityScene` (city) and `BuildingScene` (lobby plus stacked floor scenes in a rising `tower`, sharing one `CameraRig`) in one RealityView; `OfficeScene` (a floor, with `Pod`, `Terminal`, flights, the job wall and deliveries).
  - `Worker` (robot animation and faces); `CameraRig` (critically damped spring camera); `Billboard` (SwiftUI views as textured planes).
- Views: `CityViews` (`WorldView`, `TitleHUD`, `CityHUD`, `BuildingHUD`, `ReceptionComposer`, `SinceYouLeftNote`, floor list); `OfficeView` (`SceneControls`, `OfficeOverlay`, `FloorComposer`); `Cards` (request, outbox and file rows); `HiringView`; `ReceptionView`; `KitViews`; `Usage` (limits HUD).
- On-device model: `HiringDesk.swift` (hiring plan, and `ReceptionDesk` routing backed by a word-overlap check).
- Brands: `App/Brands/<id>/brand.json` → `Brand.swift` → `Palette`/`Typography` in `Theme.swift`. Never hard-code colours.
- 3D assets: `Assets/Pipeline/*.py` (Blender). KayKit sources in `Assets/Vendor`; outputs in `App/Models`. Credits are in `App/Models/MODEL-CREDITS.md` and `App/Environment/ENVIRONMENT-CREDITS.md`.

## Checking your work

- **Offscreen renders are the reliable check** (no window needed). Wrap them in a 120 s timeout, and downscale with `sips -Z 1000` before viewing:
  `build/Build/Products/Debug/TheOffice.app/Contents/MacOS/TheOffice -render-preview out.png [-theme light|dark] [-workspace "$PWD/SampleWorkspace"] [-city | -building [-floor N] | -focus <room>]`
- `-route-test "<request>"` prints Reception's routing decision (free, on-device).
- `-parallel-test` runs two small Haiku jobs on two floors at once and prints each outcome (about US$0.08; tell the owner before running it).
- Live window: `Tools/Dev/relaunch.sh <args>` and `snap.py`. Compile the helpers first with `swiftc -o winid Tools/Dev/winid.swift` and so on, and set `SCRATCH` to your scratchpad. The window often moves to another desktop Space; don't spend long fighting it.
  - The first launch after a build can take 30 s or more to show the window.
  - Quit with `osascript -e 'tell application "TheOffice" to quit'` (not `pkill`).
- Launch arguments: `-workspace`, `-request`, `-model`, `-theme`, `-replay <fixture>`, `-cli`, `-show-building`.

## Traps already found

- `claude -p` only offers `AskUserQuestion` with `--input-format stream-json --permission-prompt-tool stdio`, after an `initialize` control request.
- Background subagents make the CLI emit one `result` per turn, so the run ends on process exit, not on `result`.
- One API message arrives as several `assistant` events sharing a `message.id`; dedupe usage by id.
- Closing stdin does not stop a turn; cancel sends SIGINT, then SIGTERM, then SIGKILL.
- A one-word refresh call with the default system prompt costs about US$0.05, because it carries every skill and MCP tool. Use the bare flags in `Usage.swift`.
- RealityKit:
  - Wrapping `RealityView` in `.accessibilityElement(children: .contain)` stops the scene rendering. The VoiceOver children sit on a transparent overlay instead.
  - `BloomComponent` and `EnvironmentResource(equirectangular:options:)` need macOS 27; the target is macOS 26.
- zsh doesn't split an unquoted `$list`; use arrays when passing many files to Blender.
- Blender 5.1 USD export option names differ from older docs. See `convert.py`.
- Two `CREDITS.md` files with the same name in the app bundle stopped the resource copy, hence the prefixed names.
- `CameraRig.apply` places the camera in world space. A rig that follows a scaled scene (the city while you're inside a building) needs `frame` set, and its camera entity must not be parented under the scaled root.
- `Worker.headPosition` and `OfficeScene.overviewPose` use world positions (`relativeTo: nil`); that holds only because the building root stays at the world origin. Scale or move the city, never the building.
- Every `OfficeScene` adds its own sun; in the building view only one storey's sun is enabled, or the ground washes out.
- Kenney ships OGG, which AVFoundation can't play; convert with ffmpeg (`App/Sounds/SOUND-CREDITS.md`).
- zsh reads `$d[a1]` as an array subscript; brace variables (`${d}`) inside ffmpeg filter strings.
