# The Office

A macOS app that turns a Claude Code run into a live miniature office. Every animation comes from a real event in the `claude` CLI's stream.

## Build and run

Needs macOS 26, Xcode 27 and XcodeGen (`brew install xcodegen`).

```sh
make run      # generate the project, build, open against SampleWorkspace/
make test     # OfficeCore unit tests against fixtures/
make replay   # open and replay fixtures/three-rooms.jsonl (no API calls)
```

In debug builds, **Debug › Replay Fixture…** (⇧⌘R) replays any saved stream.

## How a job runs

1. **Reception:** type the job and choose a working directory and login (`~/.claude-*` directory).
2. **Hiring:** Apple's on-device Foundation Models picks departments from the working directory's `.claude/agents/*.md`. You can hire or release any of them.
3. **Office:** the app runs `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio`, with the hiring plan appended to the system prompt.
   - Questions (`AskUserQuestion`, manager only) and tool approvals (manager or a room, matched by `agent_id`) arrive as `can_use_tool` control requests and appear as cards.
   - A subagent the plan didn't hire works at the Contractor desk.
   - A question or approval appears as a card held up at that robot's desk, and the camera glides there: options with ⌘1–⌘9, ⌘↩ to send or allow, ⌘⌫ to deny, and Allow / Always allow / Deny stamps on approvals. The camera eases back once it's answered.
   - The HUD has a job ticket, a budget meter and a staff strip; clicking a robot opens its brief, tools and report beside the desk.
   - The side panel (⌘\, hidden by default) has **Needs you** (every waiting request), **Room** and **Kit** tabs.
   - **Always allow** hands the CLI's own suggested rule back, and the CLI saves it to the workspace's `.claude/settings.local.json`.
   - When the office needs you while it's in the background, it posts a notification and badges the Dock icon.
4. **Outbox:** the manager walks the finished folder to the outbox, which keeps the last five jobs. The Delivered card has the summary, every file the run wrote or edited (Open, Reveal), and a follow-up field that resumes the same session (`--resume`).

The budget chip on the opening screen sets `--max-budget-usd`. Quitting mid-run sends SIGINT first, because closing the CLI's stdin alone lets the turn finish.

## The city

- **City:** every project folder is a building (File › New Project…, ⇧⌘N). Beacons and labels show which buildings are working or need you; a "Needs you" list jumps straight to the waiting floor. ⌘0 returns to the city.
- **Building:** a tower of floors above a **Reception** lobby. Tell Reception what you need: the on-device model (backed by a word-overlap check) sends it to the floor whose team fits, or proposes a new floor, which goes through hiring. A busy floor queues the job. Scroll to move between floors; click one to go in. "New floor…" skips Reception.
- **Floor:** a saved team (departments, model, budget, allowed services and skills) with its own Claude session and job history. Floors run in parallel and stay until you remove them.
- **Plan limits:** the 5-hour session and weekly usage from the latest job appear top right with an "as of" time; the refresh button makes one tiny Haiku call (about US$0.001) to update them.
- **One world:** entering a building scales the city up around its lot and hands the camera over at the same pose; the façade sinks as the tower of floors rises (0.6 s). Leaving reverses it.
- **Reception** is a speech bubble at the lobby desk; the receptionist types while routing and points at the lift, whose button for the matched floor lights up. A new floor shows scaffolding on the roof.
- **Since you left:** Reception lists jobs that finished or failed since your last visit, and floors waiting for you. Buildings with deliveries you haven't seen have a parcel on the doorstep.
- The city is saved in `~/Library/Application Support/The Office/city.json`.

## Everyday use

- **Settings** (⌘,) holds the defaults for new jobs (account, model, budget), the theme, notifications, sounds and the location of the `claude` tool. The chips on the opening screen override them for one job.
- **File › Open Recent** and the Dock menu list every floor. Finished jobs are journalled in `~/Library/Application Support/The Office/jobs.json`.
- **View › Show Raw Log** (⌥⌘L) opens the raw CLI stream in its own window.
- Before a job, the opening screen checks that Claude Code is installed and signed in, and offers Install…, Locate… or Sign In… if not.
- The app icon is rendered from the scene: `TheOffice.app/Contents/MacOS/TheOffice -render-icon icon.png`.

## Branding (white-label)

Every colour, the font, the name and the logo come from the active **brand** (Settings › Branding). Built-in brands live in `App/Brands/`; custom ones go in `~/Library/Application Support/The Office/Brands/<id>/` (Settings › Open Brands Folder, or Import Brand…).

A brand folder holds `brand.json` plus any logo (`logo.svg`/`.png`) and font file it names:

```json
{
  "id": "acme", "name": "Acme", "logo": "logo.svg",
  "font": { "family": "Lexend", "file": "Lexend-Variable.ttf" },
  "light": { "background": "#…", "panel": "#…", "panelEdge": "#…", "text": "#…", "muted": "#…",
             "primaryFill": "#…", "primaryText": "#…", "floor": "#…", "walls": "#…",
             "screen": "#…", "screenPixels": "#…", "robot": "#…", "desk": "#…", "lamp": "#…",
             "folder": "#…", "error": "#…", "tray": "#…", "grass": "#…" },
  "dark": { …same keys, optional: leave out for a light-only brand… },
  "departments": ["#…", "#…"], "manager": "#…", "onAccent": "#…", "notes": "optional"
}
```

## 3D assets

- `Assets/Pipeline/robot.py` models the TV-head robot, its accessories, monitor, keyboard and mug in Blender and exports USDZ to `App/Models/`.
- `Assets/Pipeline/convert.py` converts KayKit glTF models (CC0, in `Assets/Vendor/`) to USDZ; `measure.py` prints model sizes.
- `Assets/Pipeline/tree.py` builds the street tree from the KayKit bush.
- Sounds are Kenney CC0 cues converted to AAC in `App/Sounds/` (see `SOUND-CREDITS.md`); Settings has a volume slider.
- Lighting uses CC0 HDRIs from Poly Haven in `App/Environment/`. Credits: `App/Models/MODEL-CREDITS.md`, `App/Environment/ENVIRONMENT-CREDITS.md`.
- `TheOffice -render-preview out.png [-focus <room>] [-theme light]` renders the office offscreen with sample activity.

## Layout

- `Packages/OfficeCore`: stream parser, control protocol, reducer (wire events to office events), process layer, agent catalogue. No UI imports.
- `App/`: SwiftUI screens, RealityKit scene, Foundation Models hiring desk, theme tokens, bundled Fredoka and Lexend fonts (SIL OFL, licences alongside).
- `fixtures/`: raw CLI streams the model and tests are built from. See `fixtures/README.md`.
- `SampleWorkspace/`: a throwaway workspace with `research`, `design`, `build` and `review` agents.

## Launch arguments (for testing)

`-workspace <dir>`, `-request <text>`, `-model <alias>`, `-theme light|dark`, `-replay <file.jsonl>`, `-cli <path>`, `-show-building`, `-hour <0–23>` (pins the sun's time of day). With `-render-preview <out.png>`:
- Scenes: `-city`, `-title [-rise <s>]`, `-building [-floor n | -lobby [-reception <floor index>|new]]`, `-building -world <s> [-leave <s>]` (the city-to-building transition after `s` seconds).
- Floor: `-focus <room> [-card question|approval]` (composites the desk card), `-deliver <s> [-jobs n]`, `-records <n>`.
- `-hud-test` (job ticket, meters and hiring badges), `-route-test "<request>"` (prints Reception's choice), `-parallel-test` (runs two small Haiku jobs on two floors at once; costs about US$0.08). In debug builds, **Debug › Replay Fixture…** (⇧⌘R) replays a saved stream.
