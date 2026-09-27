# Changelog

## 0.8.1

- The city and floors do less work each frame and for each stream event, so The City uses less CPU while it's open and while jobs run.
- Settings › Dictation offers Download Again when the Whisper model fails to load, so a download that was cut short no longer means choosing None and starting over.
- Fixed Ask Reception in the menu bar setting up a floor when Claude Code was missing, out of date or signed out; it now sends a notification instead.
- Fixed a floor's history staying on disk after the floor or its project was removed.

## 0.8.0

### Added

- The City has a menu bar icon that shows each project's floors and what they're doing, opens a floor, and has Ask Reception… to send a job without opening the window.
- Closing the window keeps The City running from the menu bar and removes it from the Dock; Settings › General › Show in menu bar can keep the icon there all the time.
- The city and each building have a vitals strip of rooms working, waiting and idle with today's jobs and spend, and clicking it opens a ledger with success rate, average job time and jobs over the last 7 days.
- Buildings on the city map show how many rooms are working or waiting for you.
- A floor shows how full the manager's context is and how many turns it has taken, with details of models, subagents and the floor's record.
- Selecting an agent shows a card with its status, current step and handovers, with each handover's model, tokens, tool calls and time worked.
- Step bars flag the rooms that are waiting for you.

### Changed

- Clicking a notification opens the floor it's about.
- Going into a floor is quicker, because offices are prepared in the background.

### Fixed

- Fixed a building staying at its old height on the city map after a floor was closed.
- Fixed agent cards covering the robot at its desk.

## 0.7.0

### Added

- Reception suggests a ready-made team when a request fits one of eight presets (Security Review, Bug Fix, Frontend, Code Review, Feature Build, Quick Fix, Docs & Copy and Deep Research), and sends the work to an existing floor of that kind rather than setting up a new one.
- New Security Reviewer and Debugger departments are available when hiring.
- Clouds drift high above the city and fade out when they would block the view.

### Changed

- The ground and distant woodland fade into the sky at the horizon instead of ending at a hard edge.
- The woodland has new, more varied trees.
- Buildings have window frames, sills, an entrance canopy and rooftop plant, and the cut-away building view shows windows, ceiling lights and slab edges.
- Long text in an agent's tools list, the room brief, the job ticket and the approval card scrolls, and the tools list stays on the newest command.
- A floor keeps its name after each job instead of being renamed after whatever it last did.
- The Reviewer department can no longer run shell commands.

### Fixed

- Fixed shadows under the woodland shimmering while the camera moves.

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
