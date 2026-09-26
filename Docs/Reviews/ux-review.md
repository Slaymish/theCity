# The Office: fresh-eyes UX review

Shots are in `scratchpad/ux-review-shots/` (`NN-name.png` is full size, `NN-name-s.png` is 1000 px wide). Line numbers are for the review copy.

## 1. Verdict

Today the app reads as a well-made demo of the event stream rather than a tool you'd open every morning. You see it in the first second: the opening screen's main control collapses into vertical letters (`01-reception-dark-s.png`), the job field comes pre-filled with a sample "hello.txt" request, and the File menu offers "Replay Fixture…". Once a run starts, the right-hand panel opens on raw JSON by default. The Outbox then covers most of the office and shows unrendered Markdown and CLI boilerplate. Every failure (CLI missing, not logged in, spend limit) turns up only after hiring, as a sentence with nothing to click. There is no app icon, no Settings window, no history and no way to find last week's outputs. The pieces that make it good are already there: the glass language, the question and approval cards, and live cost. Most of the work is taking things away and adding the everyday parts a Mac app is expected to have.

## 2. Prioritised findings

### P0: blocks the "finished product" feel

**P0-1. The working-directory pill collapses into a vertical column of letters.** `01-reception-dark-s.png`, `02-reception-wide-s.png` (same at 1440 pt), `03-reception-light-s.png`. `ReceptionView.swift:23-29`: the folder button has no `.fixedSize()`, unlike its three siblings, so inside the 640 pt row it gets squeezed to about 40 pt. "Hire staff" also wraps onto two lines. This is the first thing a new user sees.
*Proposal:* split the controls into two rows. Row 1: the folder pill at full width, with `.lineLimit(1)` and `.truncationMode(.middle)` and the full path as help text. Row 2: login, model, budget, Spacer, Hire staff. Give "Hire staff" `.fixedSize()`. Reuse `spacing: 8` (existing) between rows. *Effort S. Approval: yes (layout).*

**P0-2. The raw JSON log is the default panel tab.** `11-office-mid-s.png`. `RunController.swift:54,238`: `panelTab = .log`. A first-time user's whole right-hand side is `{"type":"system","subtype":"task_updated"…`.
*Proposal:* make **Needs you** the default and move the log out of the tab strip. Put it behind **View › Show Raw Log** (⌥⌘L) in a separate utility `Window` scene, so the panel has two tabs, "Needs you" and "Room". When nothing needs the user, the Needs you tab shows a short live activity feed built from `OfficeEvent` instead of the empty sentence in `14-needs-you-empty-s.png`: "Research is reading README.md", "Build wrote hello.txt", with the room colour dot at 22 pt (the step-pill value). *Effort M. Approval: yes.*

**P0-3. Test hooks and sample data ship in the product.**
- `TheOfficeApp.swift:26`: File › **Replay Fixture…** (⇧⌘R). Move it to a Debug menu compiled only under `#if DEBUG`, or show it only when ⌥ is held.
- `RunController.swift:44`: the job field is pre-filled with "Write a file hello.txt containing a one-line greeting for The Office." It should start empty, with placeholder text **"Describe the job, for example: tidy the README and fix broken links"**.
- `ReceptionView.swift:10` tagline: "Every desk is a real Claude Code subagent…" explains the concept rather than the task. Replace it with the working directory's name and the number of departments: **"SampleWorkspace · 4 departments on staff"**.
- `RunController.swift:93`: the model menu lists "fable" as a peer of Sonnet, Haiku and Opus. Use display names (**Sonnet**, **Haiku**, **Opus**) and hide anything unreleased.
*Effort S. Approval: no, apart from the tagline copy.*

**P0-4. The Outbox covers the office and shows raw text.** `12-office-later-s.png`, `13-room-research-s.png`, `20-approval-6-s.png`. `Cards.swift:160-189`, `OfficeView.swift:58-66`:
- the 520 pt card sits on top of the scene, and there's no way to dismiss or collapse it;
- the summary prints literal `**Research:**` and backticks;
- with only a sentence of content, the card still leaves a large blank area, because the summary sits in a `ScrollView` that reserves space up to 160 pt.
*Proposal:*
(a) Render the summary with `AttributedString(markdown:, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`.
(b) Let the card size to its content. Use `.fixedSize(horizontal: false, vertical: true)` up to the existing 160 pt, and only scroll past that.
(c) Add a collapse chevron to the card header, so it shrinks to a one-line bar reading **"Done · hello.txt · US$0.14"** above the step bar. Collapsing is the default for the next run's start, and Space toggles it.
*Effort M. Approval: yes (layout).*

**P0-5. Setup failures show up late and offer no way out.** `31-cli-missing-s.png`, `33-not-logged-in-s.png`, `54-live-spend-limit-s.png` (a real live run: the account's monthly spend limit). All three appear only after the user has typed the job, hired and opened the office. The error card is just prose: "Run 'claude auth login' with it", "Run failed (api_error): … raise it at claude.ai/settings/usage?from=cc_cli_limit_message". The URL isn't a link, "api_error" is shown to the user, and the follow-up field is still offered on the spend-limit failure even though nothing can succeed (`Cards.swift:196`).
*Proposal:* check readiness on the Reception screen. `loadKit()` already runs the CLI at launch, so use it. Show one status row under the job field when something is wrong, with an action button:
- CLI missing: **"Claude Code isn't installed."** [Install…] (opens the install page) [Locate…] (NSOpenPanel).
- Not logged in: **"You're not signed in to Claude Code with this login."** [Sign In…] (opens Terminal running `claude auth login` with the right `CLAUDE_CONFIG_DIR`).
- Spend limit or rate limit (`rate_limit_event` with `status: rejected`): **"Your Claude plan's limit is reached. It resets at 3:40 am."** [Open Usage Settings].
Disable Hire staff until the check passes. On end-of-run failures, show a primary button (**Try Again**, **Open Usage Settings**), make URLs clickable, drop the "(api_error)" prefix, and hide the follow-up field for account-level failures. *Effort M. Approval: no, beyond reusing existing pill styles.*

**P0-6. The app has no icon, and its name is inconsistent.** No asset catalogue exists (`project.yml`), so the Dock, ⌘-Tab and alerts show the generic icon. The menu bar reads "TheOffice" and Help says "Help isn't available for TheOffice" (`CFBundleName = $(PRODUCT_NAME)`, `Info.plist:15`).
*Proposal:* set `CFBundleName` to "The Office". Add an icon: the isometric manager desk on a navy squircle, using `background`, `desk` and `manager` tokens. Remove the Help menu item until there is help, or point it at the README. *Effort S (icon art M). Approval: yes (icon).*

### P1

**P1-1. There is no history, reuse or way to find outputs.** New Job throws the run away (`RunController.swift:336`), and only the working directory, model and budget are remembered. A returning user can't rerun "last Tuesday's job", see what it cost, or find the files it wrote.
*Proposal:* keep a small job journal (`Application Support/The Office/jobs.json`) with the request, directory, hires, cost, duration, files and session ID. On Reception, list the **Recent jobs** under the job field: up to five glass rows at radius 12 and padding 10, reusing the `HandoffDetail` values. Each row has [Run Again] and [Continue] (the latter uses `--resume` with the stored session). Add **File › Open Recent** and the Dock menu for the same list. *Effort M. Approval: yes (new section).*

**P1-2. Native app basics are missing.**
- There's no **Settings** window (⌘,). Default login, model, budget, the theme override (System / Light / Dark, replacing `-theme`), notifications and sounds belong there, which would also shorten the Reception control row.
- Window size isn't kept: `.restorationBehavior(.disabled)` (`TheOfficeApp.swift:20`) and every launch opens at the 1000×712 minimum. Keep restoration disabled for content, but remember the frame, for example by setting `NSWindow.setFrameAutosaveName("office")`.
- There is no toolbar. The window uses `.hiddenTitleBar`, and in the office "Hide panel" and "New job" are floating pills. That's acceptable as part of the look, but **View** should get **Show/Hide Panel** (⌘\ currently sits in the Job menu) and **Show Raw Log**.
- The job field doesn't accept a dropped folder or file. Dropping a folder on the window or the Dock icon should set the working directory. Dropping a file should append its path to the job text.
- Add **Services › "Give to The Office"** for selected text. It's a cheap and very Mac-like way in.
*Effort M overall. Approval: no, except for the Settings window layout.*

**P1-3. Internal wording leaks into the UI.**
- The Room › Report section shows the CLI's framing verbatim: "[Subagent hand-back] The text below is the final report of a subagent… the harness indents every line…" (`13-room-research-s.png`). Strip that preamble in the reducer.
- The contractor shows as "General-Purpose asks" (`20-approval-2-s.png`), while its tile says "Contractor". Use **"Contractor asks"** everywhere, and give the agent type as help text.
- Label changes:

| Where | Now | Proposed |
|---|---|---|
| Reception | "Default login" / "~/.claude-personal" | "Account: Personal" (folder suffix, title case) |
| Reception | "Manager: Default" (cpu icon) | "Model: Sonnet" |
| Needs you | "Always allow saves Bash(curl -sI …) to .claude/settings.local.json in the working directory." | "Always allow remembers this command for SampleWorkspace." Show the rule as help text. |
| Budget end card | "Reached maximum budget ($0.01) Raise…" (full stop missing) | "The job reached its US$0.01 budget." [Raise to US$2 and Continue] |
| Room › manager | "N handoffs so far" | "Has briefed N departments so far" |
| Desk captions | raw tool names ("Glob", `10-office-start-s.png`) | verbs: "Searching", "Reading", "Writing", "Running a command" |

*Effort S. Approval: no.*

**P1-4. Department colours change with hire order.** `Palette.accent(forHireIndex:)` (`Theme.swift:33`). Build is teal in `08-hiring-again-s.png`, then blue after releasing Research in `52-live-hiring-edited-s.png`, and purple in a replay. A department's colour is its identity in the office, in the step bar and on its cards, so it shouldn't move.
*Proposal:* assign the colour from the department's position in the catalogue (`AgentCatalogue` order), not from its hire order. It's the same four tokens, cycled the same way. *Effort S. Approval: no (same tokens).*

**P1-5. Room labels are hard to read in dark mode.** Labels use `Palette.text` (#EEF1FA) on the department tiles (`OfficeScene.swift:226`). Measured contrast is 1.83:1 on #E8A84E, 1.97 on #5CBFA6, 2.21 on #6FA8E6, 2.39 on #A891E0 and 2.40 on #E57F8E. The labels are also system bold, not Outfit.
*Proposal:* draw each label in `Palette.textOn(tileColour)`. That token already exists and gives 6.4–8.4:1 on the accents. It resolves to `background` on muted tiles, so the Contractor and Outbox labels get 5.6:1 in light mode instead of 2.7:1. Build the mesh with the Outfit 600 font the app already registers. *Effort S. Approval: yes (label colour).*

**P1-6. The on-device hiring is inconsistent and its "Why" lines say nothing.** For the same one-line "hello.txt" request, three hiring rounds gave Research→Build→Review, Research→Design (no Build at all), and Research→Design→Build (`05-`, `08-hiring-again-s.png`). The live run hired all four (`51-live-hiring-s.png`). The "Why" lines mostly repeat the department description: "Why: design is needed to design how…".
*Proposal:* in `HiringDesk`, add a `@Guide` asking for the fewest departments that finish the job, and include two short examples in the instructions. Hide `reason` when it largely repeats the description. Replace the "Why:" label with a quote in muted colour. *Effort S. Approval: no.*

**P1-7. Hiring can't be done from the keyboard, and the Reality scene isn't accessible.** Departments can only be reordered by drag (`HiringView.swift:40`) and have no drag handle. The office floor shows up in the accessibility tree as an unlabelled `AXUnknown` element: the label set on the `GeometryReader` doesn't reach it.
*Proposal:*
- Add a `line.3.horizontal` handle at the row's trailing edge, plus **Move Up** and **Move Down** (⌥⌘↑/↓) as accessibility actions and menu commands.
- Put the accessibility label on the `RealityView` itself, and add one `accessibilityChildren` button per room: "Research, working, 12 seconds". The step bar already builds exactly this text.
*Effort M. Approval: no.*

**P1-8. Hiring can sit on a spinner for a long time with no progress shown.** Hiring waits for `kitTask` (`RunController.swift:201`). The kit load has a 20 s timeout, but `claude mcp list` has none (`KitLoader.swift:35-52`). My first hiring round was still spinning at 45 s. Later rounds took about 5 s.
*Proposal:* give `mcpList` a 10 s timeout. Start the on-device plan without waiting for the kit, and merge skills in when they arrive. After 3 s, change the caption to **"Still reading. You can pick departments yourself."** and enable the Hire toggles straight away. *Effort S. Approval: no.*

### P2

- **P2-1. The counter card is hard to read** (`OfficeView.swift:92-123`). Put cost on the top line ("US$0.14 of US$1.00"), then time as `m:ss` ("0:14" rather than "13.8s", and "10:12" rather than "612.4s"), then tokens in `muted` ("148k tokens"). Remove the "≈". Show a live estimate in `muted` and turn it `text` when the final figure arrives. The step pills should use whole seconds. *S, approval: yes (order).*
- **P2-2. The scene leaves a lot of empty floor** (`31-cli-missing-s.png`): `max(hired.count, 3)` means a one-room office still gets a three-room floor. Size the floor to the rooms actually hired, plus the manager, contractor and outbox row. *S, no.*
- **P2-3. The job card is a caption-sized repeat of the request** (`JobCard`). Make it selectable. Add ⌘C, and a hover-only **Edit and Run Again** button that returns to Reception with the text filled in. *S, no.*
- **P2-4. The Files list** (`FileRow`) uses the pill "Open" and "Reveal" buttons. That's fine, but also: double-click the row to open it, add Quick Look on Space, allow dragging a row out to Finder or Mail, and add a context menu with Copy Path and Share…. *S, no.*
- **P2-5. Notifications** (`Attention.swift:30`): "The artefact is in the outbox." should name the file: **"hello.txt is ready."** Add actions **Open** and **Show in The Office**. Approval notifications should offer **Allow** and **Deny** actions (`UNNotificationCategory`), so a quick approval doesn't need a trip back to the window. *M, no.*
- **P2-6. The "Hired"/"Hire" toggle reads as a status.** Change the unhired label to **"Hire"** and the hired label to a filled pill with a checkmark, "✓ Hired". The accessibility label already says "Release …". *S, no.*
- **P2-7. The Brand wordmark sits in the top left of the office.** It pushes the job card down and serves no purpose in the office. Put the request in its place, and keep the big wordmark on Reception only. *S, approval: yes.*

## 3. Five delight moments (cheap)

1. **Lights on.** When the office opens, desks light up one after another in hire order, 80 ms apart, reusing `setActive`'s lamp with its point light, before the run starts. It's skipped under Reduce Motion. It costs almost nothing and makes "hiring" feel like it happened.
2. **The folder lands.** When the artefact reaches the Outbox tray, give it a small settle bounce (0.08 up, then 0, reusing the bob values) and play the system "Glass" sound, only when the app is frontmost and sounds are on in Settings. The Dock icon bounces once if the app is in the background.
3. **A small daily record.** On the collapsed Outbox bar, add one muted line when it's true: "Fastest hello yet: 14 s" or "Under budget by US$0.86". The journal from P1-1 already has the data.
4. **Hand up, name up.** When a desk raises its hand, float its room colour's pill above the desk ("Build has a question") using the existing caption mechanism, and make clicking the desk jump to the card. At the moment the raised arm is almost invisible (`21-question-1-s.png`).
5. **Clocking off.** When a run finishes, each robot turns its screen off and the tile dims for 0.3 s. Hovering a desk afterwards shows "Worked 4 s · 3 tools". This reuses `StepPill` data.

## 4. Keep

- The Needs you cards. The question card (`21-question-1-s.png`), with ⌘1–⌘9, "Other…" and ⌘↩, and the approval card (`20-approval-2-s.png`) are the best parts of the app: clear, keyboard-first, and properly coloured by room.
- The glass tokens, Outfit and DM Mono, the navy palette and light theme, and the pill buttons. Both themes hold up well apart from the contrast issue in P1-5.
- The step bar as the way into each room, with live timers.
- Live cost against the budget, the budget cap itself, and SIGINT-on-quit.
- The on-device hiring as a free and quick first draft, with the user able to override it.
- Follow-up that resumes the same session.
- The existing Reduce Motion handling, and the VoiceOver announcement when a room needs you.

## 5. What I verified vs only read

**Ran and saw:** Reception in dark, in light and at 1440 pt (the P0-1 collapse happens in all three). Hiring: three on-device rounds with different plans, the spinner delay, releasing departments and seeing the colour shift, and the no-departments state with an empty workspace. Office replays of `three-rooms`, `approval-requests`, `ask-question`, `budget-exceeded` and `not-logged-in` in both themes. The Room inspector, including the leaked hand-back text. CLI missing via `-cli /nonexistent`. Menu contents: no Settings; Replay Fixture present; Help shows "Help isn't available for TheOffice" with the generic icon. The accessibility tree dump, where the floor appears as an unlabelled `AXUnknown`. Label contrast calculated from the tokens.

**One live run** (Haiku, Build only, US$1.00 budget) ended immediately with the account's monthly spend limit (`54-live-spend-limit-s.png`), at a reported cost of US$0.00. I didn't try a second. So I have not seen a real run's Outbox with files written, Open/Reveal on a real file, a follow-up, Always allow persisting a rule, notifications or the Dock badge (the app was frontmost throughout), or the keyboard shortcuts on live cards. Those findings (P2-4, P2-5) are from reading the code only. VoiceOver itself, keyboard-only navigation and the Reduce Motion behaviour were also only read in code, not exercised. `SampleWorkspace` is unchanged (only `README.md` and `.claude/`).
