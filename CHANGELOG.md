# Changelog

## 0.6.0

### Added

- Each floor has a terminal kiosk: click it, or choose Take over, to carry on the floor's Claude Code session in a terminal, and Leave (esc) goes back to the floor while the terminal keeps running.
- Floor History (⌘Y, or the History button) lists a floor's past requests and results, with a Copy button.
- Press ⌥Space in a prompt to dictate; speech is turned into text on this Mac, after you download the Whisper model in Settings › Dictation.
- The city, buildings and offices follow the time of day on your Mac, with sunrise from 06:00 to 07:00 and dusk from 18:00 to 19:30.
- At night the streetlights, car headlights, office windows, desk lamps and standing lamps light up.
- The city is surrounded by meadow, rocks and woodland, and parks have grass and flowers.
- Parks and the empty lot have a streetlight, like the building lots.

### Changed

- The camera flies in an arc when you go into or out of a building and when you reset the view.
- Daytime light comes more from the sun, so shadows are crisper.

## 0.5.0

- ⌘↩ accepts Reception's suggested action once it's showing.
- Times on the counter, step bars and trophies show as m:ss, such as 0:14 rather than 14s.
- VoiceOver reads how long each room has been working, such as "Research, working, 12 seconds".
- Fixed the camera passing through the first floor, and trees blocking the view, when you type to Reception.
- Fixed Reception's suggestion buttons being clickable while routing was still running, which could start the wrong job.
- Fixed delivered files showing full paths instead of project-relative ones when the project is behind a symlink, such as under /tmp.

## 0.4.0

### Added

- Reception can continue a floor's last job as well as start a new one, and says that a new job starts without the last job's conversation.
- Floors show whether Claude Code is installed and signed in before you start a job, with Install…, Locate…, Sign In… and Open Usage Settings buttons.
- Failed jobs have a Try again button, and the delivery card shows the same setup buttons when Claude Code is missing or signed out.
- When the demo finishes, its floor offers Break ground on your own project… and Watch again instead of a composer that can't run jobs.
- Settings has an Updates tab with the version and a Check for Updates… button.
- View › Reset View puts the camera back after you've orbited, zoomed or panned.
- Help › The City Help (⌘?) opens the guide on GitHub.

### Changed

- Open In is split into a button that opens the project in the app you used last and a menu for choosing another.
- Notifications name the building and floor they're about.
- Approval cards say which rule Always allow saves, and the stamp reads "Always allowed".
- The floor panel's tabs are now Activity (Needs you when something's waiting), Room, and Tools & skills.
- Remove from City… asks before removing a project and its floors.
- Panning stops within reach of the scene, so the view can't be lost.
- While a question card is showing, ⌘1–⌘9 answer it instead of switching floors.
- Space toggles the delivery card, and deliveries after the first show collapsed.
- The job ticket's text can be selected and copied.
- The Hired button shows a checkmark so it reads as a toggle.
- Reception gets ready while you type, and if it takes longer than 12 seconds it asks you to choose a floor instead of waiting.
- The Settings model picker lists models before you've opened a floor.
- Plan usage refresh errors show in the usage bar instead of only in a tooltip.

### Fixed

- Fixed Watch a demo overwriting your saved plan usage with the recording's numbers, and posting notifications while The City was in the background.
- Fixed the loft poking through the ceiling.
- Fixed MCP terminal labels being drawn at a different size from desk bubbles.
- Fixed failure messages telling you to fix Claude Code "from the opening screen", which no longer exists.

## 0.3.0

- The welcome screen has a Watch a Demo button that replays a recorded job on a sample floor, so you can see the office working without spending any tokens or changing your city. Thanks to @Tenkeren11 for building it.
- Jobs can't be started from the demo floor, which explains that it only replays a recording.

## 0.2.0

- Settings › Accounts has an Add Account… button that names a new Claude account and opens Terminal so you can sign in to it.
- Settings is split into General, Accounts, Appearance and Alerts tabs, so it fits on smaller screens.
- New jobs now default to a US$5 budget instead of US$1, unless you've already picked one in Settings.
- The city stops rendering while its window is minimised or fully covered, so it uses far less CPU in the background.
- If Terminal can't be opened to sign in, The City now shows an error instead of doing nothing.

## 0.1.1

- New app icon: a city block with its robot out front.
- New jobs now ask before every tool by default instead of running in Auto mode, unless you've picked a mode in Settings.
- The City now needs Claude Code 2.1.163 or later, and Reception explains how to update an older version before running a job.
- Approval notifications no longer have an Allow button, so tools can only be allowed from the desk card; Deny still works from the notification.
- Updates are only accepted from a signed feed and are verified before they're unpacked.
- Fixed Sign In… failing when the path to Claude Code or the account folder contains an apostrophe.

## 0.1.0

First public release.

- City view: each project folder is a building, with beacons for buildings that are working or need you and a "Needs you" list.
- Buildings of floors above a Reception lobby. Each floor is a saved team with its own Claude session, model, budget and job history, and floors run in parallel.
- Reception routes a request to the floor whose team fits, taking into account work already running on other floors, or proposes a new floor. A busy floor queues the job.
- Hiring picks departments from the project's `.claude/agents/*.md` using Apple's on-device model, with a word-overlap fallback.
- Live office scene driven by the `claude` CLI's stream-JSON output, including subagents at their own desks and a Contractor desk for unplanned ones.
- Questions and tool approvals as cards at the robot's desk, with keyboard shortcuts and Always allow.
- Delivered card with a summary, changed files and follow-up that resumes the session.
- Budget limit per job, 5-hour and weekly plan usage display, and a raw log window.
- Plan usage is tracked per account: the gauges show a row for each account, the Account menu shows each one's usage, and Settings can hide accounts you don't use.
- Checks that Claude Code is installed and signed in, with Install…, Locate… and Sign In… options.
- Background notifications and Dock badge when a floor needs you.
- Light and dark themes, custom brands, sounds and haptics.
- Automatic updates via Sparkle, with a Check for Updates… menu item.
