# The Office: vertical-slice game review

Screenshots are in `game-review-shots/`. All but one are offscreen renders from the review copy's build. `earlier-live-floor-panel.png` is a live-window capture that an earlier session took of the main repo's build; I include it only to show the overlay, whose code matches the copy. File references are to `game-review-copy/App/`.

## 1. Verdict

The robots and the TV-face expressions, the arcing folders and the fact that it's all driven by real events are proper game material. The robot's "?" face (`focus-review-light.png`) already does the job of a game character. What makes the app feel like a web app is everything around that core. Every place you actually do something is a floating glass form: the welcome paragraph, the Reception text box, the hiring list, the tabbed side panel and the outbox card. The world is a diorama floating in a flat blue void (`city-light.png`, `building-light.png`), with no horizon, no people moving and no sound apart from one system chime, and the city-to-building step is a hard cut between two separate scenes. The moments that matter most (a robot needs you, the work is delivered) happen in a text panel at the side while the world only shows a generic "Has a question" label. So the world illustrates the work but isn't yet where the work happens.

## 2. The game it should be

**Pitch.** *The Office* is a sunny little company town you run by handing over work. Each project is a building on its own lot. You walk a job into the lobby and the receptionist sends it upstairs. You watch a floor of TV-headed staff pass folders between desks, and when someone raises a hand you go over and answer them face to face. Finished work arrives as real objects in the outbox that you can open, and over weeks each floor gains the marks of the jobs it has done. It stays honest: every cost, file, question and error is on the object it belongs to, never hidden to keep you playing. It differs from other "AI office" visualisers in three ways: projects are buildings in a city, the world state is the real CLI stream, and deliverables are physical objects you collect.

**Core loop**
1. **Brief:** hand a job to Reception, which routes it to a floor or sets up a new one.
2. **Watch:** the floor comes alive and folders travel between desks.
3. **Unblock:** a hand goes up, you go to that desk, answer or stamp the request, and the robot carries on.
4. **Collect:** the manager walks the result to the outbox and you open what was made.
5. **Tend:** the floor keeps a trace of the job, and you pick the next one or come back tomorrow.

**The verb is "hand over".** Everything should feel like passing a folder: a job to Reception, a folder to a desk, an answer to a robot, a delivery to you. Today the verb is "type into a field".

## 3. Prioritised proposals

"Visuals: yes" means it changes approved visuals and needs sign-off.

### P0: make the world the interface

**P0-1. One continuous world: no cut from the city to the building.**
*Problem:* tapping a building runs `flyTowards` for 450 ms and then swaps the route (`CityViews.swift:57-61`), which tears down the `CityScene` RealityView and builds a separate `BuildingScene` (`ContentView.swift:15-20`). The tower in the building view doesn't look like the KayKit building you clicked, and there's no city around it (`building-light.png`).
*Proposal:* one world entity. The KayKit building on the lot is the tower's exterior shell. On tap: camera dolly towards the lot (reuse `CameraRig.focus`, smoothTime 0.5 s), the front and left façades slide down into the ground, and the storeys (the existing `OfficeScene` roots) rise out of it as the camera arrives. Going back reverses this. Neighbouring buildings stay in shot, so you always know where you are.
*Effort:* L. *Visuals:* yes. Façade slide 0.6 s, **new, needs approval**.

**P0-2. Put the diorama on the ground.**
*Problem:* the city is a slab floating in `background` (`CityScene.swift:49`, `city-light.png`). In the building view the lobby is a 12 × 10 slab with one desk (`BuildingScene.swift:49-55`) on a ground plate that the frame cuts off (`BuildingScene.swift:66`). The roof floats with no walls under it (`:81`). Inside a floor, the floors below still render through the open slab (`BuildingScene.swift:138`, `floor1-light.png`, where the Manager and Outbox from the floor below appear under this one).
*Proposal:*
- Extend the ground to the horizon in a new **`grass`** token: the-office light `#BFE3A0`, dark `#5E7A4F` (**new token, needs approval**). Other brands inherit it the way Alphero already inherits the prop tokens (`Brands/alphero/brand.json` notes). Put a ring of KayKit/Kenney trees at the city's edge so there's no edge to see.
- Build a proper lobby floor: a glass door, a waiting sofa (`couch_pillows` is already bundled), a lift panel, and a receptionist robot behind the desk. The desk is already a `Pod` with a tie.
- When you enter a floor, turn off every other storey, not only the ones above (`other.index <= storey.index` becomes `==`).

*Effort:* M. *Visuals:* yes.

**P0-3. Hands up: questions and approvals happen at the desk.**
*Problem:* the world shows only "Has a question" or "Needs approval" (`OfficeScene.swift:333`). The actual question, options and command appear in a side-panel card (`Cards.swift:14-66`), which also forces the panel open (`RunController.swift` in `track`, `showPanel = true`). You read the key moment of the game in a sidebar.
*Proposal:* when `handRaised` fires, the camera glides to that robot (reuse `OfficeScene.focus(room:)`) and the robot holds up a card. Next to it, a SwiftUI **speech card** sits pinned to the robot's projected head position. The projection maths already exists in `OfficeScene.room(at:)`, `:267-285`.
- Questions: the header in eyebrow style, the question in `bodyMedium`, and each option as a chunky tile using the room's colour (reuse `OptionButton`). The ⌘1–⌘9 hints stay, and so does "Other…".
- Approvals: a **permit slip** reading "**Build** would like to run:" with the exact command in `Typography.code`, and three stamps: **Allow** (⌘↩), **Always allow in <folder>**, **Deny** (⌘⌫). The "Saves Bash(...) to .claude/settings.local.json" tooltip stays.
- Tapping a stamp thumps the slip. The slip flies back to the robot as a folder (reuse `fly`), the robot's face goes from "?" to "– –" and it goes back to typing.
- Two or more waiting: the extra robots keep their hands up, and a counter chip "2 more waiting ›" moves to the next one.

The side panel's **Needs you** list stays as the keyboard and VoiceOver path, and the notification actions in `Attention.swift` stay unchanged. Speech card width 360 pt, **new, needs approval**; everything else reuses `RequestCard` values.
*Effort:* M. *Visuals:* yes.

**P0-4. Swap the panel chrome for a game HUD, with no information lost.**
*Problem:* the floor view has "Hide panel" / "Cancel" pills, a monospaced counter, and a tabbed panel whose default content is a chat-like activity log (`OfficeView.swift:103-131`, `:408-435`; `earlier-live-floor-panel.png`). That's the part that most reads as a web dashboard.
*Proposal:*
- **Top left, a job ticket:** the `JobCard` becomes a paper ticket with a perforated edge, showing the request plus "Then: …" follow-ups.
- **Top right, a meter cluster:** a budget gauge that fills from 0 to the budget (`$0.42 of $1.00`), the clock, and tokens. Text stays exactly as it is now; only the container changes, and figures switch to the brand font's tabular numerals instead of system mono (`Theme.swift:112`).
- **Bottom, a staff strip:** revive the unused `StepBar` (`OfficeView.swift:301-363`) as portraits. Each is the robot's face texture (already rendered in `Worker.texture`) plus a timer, and tapping one focuses that robot.
- **Robot "character sheet":** clicking a robot opens the Room inspector (brief, tools, report) as a card anchored to the desk rather than a tab.
- Kit becomes a clickable wall board by the MCP terminals.
- The raw log stays behind ⌥⌘L.
- The panel remains available with ⌘\ for people who want it, but closed by default.

*Effort:* M. *Visuals:* yes.

**P0-5. The outbox is where you get paid off.**
*Problem:* the delivered folder lands on a small tray (`OfficeScene.swift:360-367`), then all delivered items are deleted when the next job starts (`reset()`, `:385-386`). The result appears as a 520 pt glass form with Open/Reveal pills (`Cards.swift:187-241`).
*Proposal:*
- The manager stands up, carries the folder to the outbox and drops it in: squash on landing, the "Glass" chime replaced by a delivery cue (see P1-3).
- One sheet per file stacks in the tray, and the tray keeps the last 5 jobs. Older ones go into the cabinet drawer and remain available as history.
- Clicking the outbox focuses it and opens a **delivery card**: title "Delivered", the summary, then each file as a paper row with its icon (keep `FileRow` with Open, Reveal, Quick Look on Space, and drag). Below that go cost/time/"Under budget by $0.58" (the existing `recordLine`) and the follow-up field.
- Failure is also physical: the folder turns `error` red (already done) and the manager holds it up with "× ×", with the reason on the card.

*Effort:* M. *Visuals:* yes. Tray keeps 5 jobs, **new, needs approval**.

**P0-6. First launch is a title screen, not a paragraph.**
*Problem:* `WelcomeView` (`CityViews.swift:23-37`) is a wordmark, a sentence and a button on a flat colour.
*Proposal:* open straight into the city scene with one empty lot, the receptionist robot waving next to a "For sale" sign, the brand wordmark top left, and the button **"Break ground on your first project…"**. See signature moment A.
*Effort:* M. *Visuals:* yes.

### P1: life, feel and sound

**P1-1. Ambient life (it's a living world, not a slot machine).**
*Problem:* the cars are parked and never move (`CityScene.swift:142-151`). Beacons are grey spheres (`:96`). An idle robot only bobs and turns its head (`Worker.swift:143-163`).
*Proposal:*
- **City:** 3–4 cars drive the road loop at walking pace, pedestrians are small versions of the robot, and cloud shadows drift across the ground.
- **Building status on the building itself:** windows lit in `lamp` per working floor, a hand-raise balloon above the roof when something needs you, and a small pennant on the roof when a job is done. This replaces the grey beacon and the "· 0 floors" label (`CityScene.swift:221`).
- **Idle routines on floors:** between jobs, robots take turns walking to a water cooler or the armchair, stretching, or watering the cactus. There's never more than one on the move at a time, and all of them snap back to their desks the instant an event arrives.
- **Time of day inside the approved "sunny daytime":** the light angle follows the local clock between 08:00 and 18:00. The dark theme is warm dusk, with `lamp` lights on and screens glowing, instead of a flat purple room. Note that in dark mode the outbox tile uses `muted` and ends up as the brightest thing on the floor (`OfficeScene.swift:109`, `office-dark.png`); it should use `tray`.

Everything respects `reduceMotion`, as the code already does. *Effort:* M. *Visuals:* yes.

**P1-2. Juice on the existing motion.**
*Problem:* the folder flight is a smoothstep arc with a full spin (`OfficeScene.swift:431-435`). There's no anticipation or landing, and moods change instantly.
*Proposal:*
- **Folders:** anticipation of a 0.12 s lift of 0.15 m before launch; land with a squash to (1.15, 0.8, 1.15) and back over 0.15 s; spin reduced to a quarter turn.
- **Mood changes:** a small head bob (0.1 s) whenever the face texture changes.
- **Done:** the "★" face plus a 0.25 m hop.
- **Lights-on stagger:** keep the existing 90 ms stagger (`:212`) and add a chime per desk at rising pitch.
- **Camera:** keep the critically damped rig. Add a 2° pitch settle on arrival for focus shots only.

All numbers except the reused 90 ms and 1.1 s hop time are **new, needs approval**. *Effort:* S.

**P1-3. Sound design.**
*Problem:* the only sound is `NSSound(named: "Glass")` on delivery (`OfficeScene.swift:367`).
*Proposal:* a cue list, mixed quiet, with a volume slider in Settings next to the existing "Sounds" toggle. The existing guard (`NSApp.isActive`) stays.
- Keyboard patter while a desk works: very low, one shared loop.
- Paper whoosh for a handoff.
- Soft "boop" for a hand raised, and a two-note rising ping if you're elsewhere in the app.
- Stamp thump for Allow, drier thud for Deny.
- Tray drop and a small bell for delivery.
- Lift ding when entering a floor.
- Faint outdoor ambience in the city, room tone on floors.

Source: Kenney **Interface Sounds**, **Impact Sounds** and **UI Audio** (all CC0); ambience recorded or synthesised yourself. *Effort:* M.

**P1-4. Reception and hiring as places.**
*Problem:* Reception is a 560 pt glass text box (`CityViews.swift:273-303`); hiring is a list of rows with Hire pills (`HiringView.swift:81-118`).
*Proposal:*
- Reception: the camera sits at the lobby desk and the receptionist robot faces you. You type into a speech bubble ("What do you need done in theOffice?").
- While the on-device model routes the job, the receptionist taps at its monitor ("– –" face); keep the existing copy "The receptionist is checking which floor fits…".
- The suggestion is shown by the receptionist pointing at the **lift panel**, where the matched floor's button lights up ("Send to Security review"), with the quoted reason in a bubble.
- "Set up a new floor" shows a floor being built as a scaffold. Hiring becomes a row of **ID badges** (robot face + accessory + description). Tap to hire and drag to reorder, as today. Kit sits on the same screen as a toolbox tray.

*Effort:* L. *Visuals:* yes.

**P1-5. Returning the next day.**
*Problem:* the journal's `recentJobs` (`CityStore.swift:229`) is never shown, although the README says the opening screen has "Recent jobs" (`README.md:34`).
*Proposal:*
- On launch, the camera starts on the city. Buildings with unopened deliveries show a parcel on the doorstep.
- A small "Since you left" note on the Reception desk lists finished, failed and waiting jobs with their cost, one line each, each opening the right floor. It's factual, with no streaks.

*Effort:* S–M.

### P2: meaning and polish

**P2-1. Floors that remember, with no manipulation.**
Each completed job hangs a small framed card on the floor's wall showing the job's title, date and cost. The wall holds the last 12 jobs (**new, needs approval**), and the rest go into an in-world "Records" binder (the journal). The existing `recordLine` ("Fastest job in theOffice yet") becomes a desk trophy that moves to whoever holds the record. The desk plant grows one stage per 10 completed jobs on that floor. Explicitly **no** streaks, daily rewards, loot, energy timers, badges for spending, or nudges to run more jobs. Cost always stays visible on the object. *Effort:* M. *Visuals:* yes.

**P2-2. Haptics.** `NSHapticFeedbackManager` `.levelChange` when a stamp lands and `.alignment` when an option is picked, on Force Touch trackpads only. *Effort:* S.

**P2-3. Polish list (things that look unintentional).**
- The raised or typing arm reads as a white brick lying on the desk in close-up (`focus-review-light.png`, `focus-build-light.png`; `Worker.swift:148-149`). The arm rig needs an elbow, or a hand/paper held up.
- In focus view the room banner covers the left third of the frame, and the bubble is clipped at the top edge (`focus-review-light.png`). Hide banners in focus the same way signs are hidden (`OfficeScene.swift:239`), and lower the bubble.
- City labels say "theOffice · 0 floors", which is dashboard copy. Use "Empty lot" / "2 floors · all quiet" only on hover.
- The "New project" lot is a blank white pad (`city-light.png`; `CityScene.swift:114-127`). Use a "For sale" sign and some construction cones.
- The counter uses system monospaced type while everything else uses the brand font (`Theme.swift:112`).
- MCP terminal labels are tiny next to the banners (`office-light.png`, back wall).
- Dead views: `StepBar`, `ContinueCard`, `SignView` and `workSummary` are never used (`OfficeView.swift`, `Billboard.swift`). Either revive them (P0-4) or delete them.
- Two robots on a three-desk floor leave a large empty stretch (`floor1-light.png`). Pack the pods by hire count, or fill the space with a shared kitchen or meeting nook.

## 4. Three signature moments

**A. Breaking ground (first launch to first building).**
1. The city fades up at golden daylight. The camera slowly orbits one empty lot with a "For sale" sign. The receptionist robot stands on the pavement with "^ ^" and waves (arm at −2.75, as in the question pose).
2. The wordmark and the button "Break ground on your first project…" appear.
3. The folder picker opens. On confirm, the sign pops off with a squash, dust puffs in (Kenney CC0 particle sprite), and the KayKit building rises out of the lot over 1.2 s (**new, needs approval**), overshooting 5% and settling, with a deep "thunk" and a bell.
4. The name board slides onto the façade: "theOffice".
5. The robot walks in through the door, and the camera follows in (P0-1) to the lobby.
6. The receptionist is at the desk, and its speech bubble is the text field: "What do you need done in theOffice?"

**B. Hand up (a question or an approval).**
1. The event arrives. The robot's face flips to "?" with a head bob, the arm goes up, and there's a soft "boop". If you're on another floor, the hand balloon rises from that storey and the HUD chip reads "Review needs you ›".
2. The camera glides to the desk (0.5 s). The other desks' banners stay visible but their bubbles hide.
3. The speech card unfolds from the robot's head over 0.2 s (**new, needs approval**): "**Review** would like to run:" / `npm test -- auth` / Allow · Always allow in theOffice · Deny.
4. You press ⌘↩. An Allow stamp slams onto the slip (thump, and a haptic on the trackpad), and the slip folds into a folder.
5. The folder flies back into the robot's hands, the face turns to "– –", the typing loop resumes, and the camera eases back to where you were.

**C. Special delivery (the job is done).**
1. The final `result` arrives. The desks' faces turn "★" one after another at the existing 90 ms stagger, with rising pings.
2. The manager stands, picks up the job folder, and walks it to the outbox. While it walks, the camera frames the outbox.
3. The folder drops, and the tray squashes. Sheets fan out, one per file, each with a filename label that billboards briefly: "hello.txt".
4. A bell rings. The delivery card rises from the tray: "Delivered", the summary, files (Open · Reveal · Space to preview), "$0.42 of $1.00 · 1:12 · Under budget by $0.58", and "Ask for a change or a next step…".
5. A framed job card slides onto the wall (P2-1). The floor goes quiet: robots stretch and one goes for coffee.

## 5. What to keep

- The TV-face robots, the expression set (`Worker.swift:11`) and the department accessories: a clear, readable and likeable cast.
- Every animation coming from the real stream. Don't fake activity; ambient life should only fill idle time.
- The critically damped `CameraRig`, and the single shared camera between building and floor.
- The room-colour rugs plus banners as a readable board: you can tell who's who from far away (`office-light.png`).
- The folder as the unit of work. It's the verb; build on it.
- Accessibility work that most games skip: Reduce Motion everywhere, VoiceOver children on the floor, keyboard shortcuts on every request, and actionable notifications. The in-world versions must keep all of it.
- The token-driven white-label system and the rule that the scene reads colours from `Palette`.
- Honest numbers: live estimate versus final cost, and budget chips.

## 6. Verified by running vs read in code

**Ran (offscreen renders from a fresh `make build` of the review copy):**
- City (light and dark).
- Building overview.
- Inside floor 1 (Security review).
- Standalone office (light and dark).
- Close-ups on Review (question) and Build (working).

All of these use the renderer's own sample data (`OffscreenRenderer.swift:46-142`), so the floor labels and the "0 floors" city labels reflect that data.

**Not run:** the live window. Another instance of The Office (the main repo's build) was already running with a live `-request`. Launching mine would have shared its `~/Library/Application Support/The Office/` state, and the `relaunch.sh` helper quits any app named "TheOffice". So I didn't launch, back up or modify anything there. No replays and no live Claude runs.

**Read in code, not seen:** every SwiftUI overlay (welcome, Reception composer, hiring, side panel, request cards, end card, HUD positions), the city-to-building cut, sounds, notifications, idle behaviour over time, and the dead views. `earlier-live-floor-panel.png` is a capture another session took at 03:07 of the main repo's build. I used it only to confirm the panel layout, which matches the copy's `OfficeOverlay`. I haven't seen sael.net/ai-office, so the distinctness claims rest on this app's own features, not on a comparison.
