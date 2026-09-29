# The City: design direction

Status: **for sign-off.** Everything marked *(needs approval)* is a new size, colour, timing or piece of copy, so per `.claude/rules/app.md` it doesn't ship until the owner agrees. Slice 1 (section 10) uses existing tokens only.

Method: discovery, audit, principles, concept, information architecture, interaction model, visual and motion system, accessibility, validation, delivery plan. Evidence is the code at `bf3a068` (0.13.0), the README reels, and the two earlier reviews in `Docs/Reviews/`. **Not yet checked:** a live window or fresh offscreen renders. This was written in a Linux session that can't build the app. Every claim about how a screen looks comes from code or the reels, and the first job in section 11 is to confirm them with renders.

---

## 1. Brief

**Product.** A macOS 26 app (plus an iPhone companion) that turns real `claude` CLI events into a city of robot-staffed offices. Project = building, job stream = floor, subagent = robot at a desk.

**Audience (decided).** Both, power user first. The primary user is a developer with 2 to 5 Claude Code jobs running across several projects, who is doing other work and looks at the city in glances. The first-run experience is a second, marketing-grade surface that has to work with no explanation.

**North star (decided): ambient awareness.** At any moment, in about two seconds, the user can tell:
1. Is anything **blocked on me**?
2. Is anything **finished** that I haven't seen?
3. Did anything **fail**?
4. What is **running**, and roughly how long has it been going?

Everything else (spend, tokens, history, tools) is secondary and must never compete with those four for attention.

**Ambition (decided): re-think everything.** The robots, the diorama world and the camera rig are the assets worth keeping. Navigation, chrome, hierarchy and the status vocabulary are open.

**What good looks like.**
- A glance from across the desk reads the whole city's state, without reading text.
- A blocked robot is impossible to miss and impossible to lose, however deep in a building it is.
- The same thing looks and sounds the same everywhere: city, building, floor, menu bar, Dock, notification and phone.
- The world is charming, and the charm never costs the user a second of attention that the north star needed.

---

## 2. Audit: what's working against the north star

Severity: **A** blocks the north star, **B** costs attention, **C** polish.

| # | Finding | Evidence | Sev |
|---|---|---|---|
| 1 | **"Needs you" is three different things.** A robot blocked on an approval, a finished result you haven't opened and a failed job all count as one number and one pill. A blocked job is burning wall-clock time. A finished one can wait until lunch. They should not sort together or look alike. | `CityStore.needsYou` adds `pendingRequests.count` to `unseen ? 1 : 0`. `NeedsYouList` shows one hand icon for all. | A |
| 2 | **There is no status vocabulary.** `RoomState` has three cases (waiting, working, idle) for rooms. Buildings get a `(working, waiting)` tuple. Floors get `unseen`. Failure has no state of its own outside the end card. Each level re-invents its own icon and colour rule. | `Billboard.swift:225`, `CityStore.status(of:)`, `Attention.finished` | A |
| 3 | **Time is invisible.** A robot that has waited 20 seconds looks the same as one that has waited 20 minutes. Ambient awareness is mostly about *how long*. | No age on `PermissionRequest` in any HUD | A |
| 4 | **Awareness lives in HUD lists, not in the world.** The city's status is a row of pills at the bottom and a "Needs you" glass card. The buildings are the largest objects on screen and carry no readable state from a distance. | `CityHUD`, `ProjectList` | A |
| 5 | **The floor screen has about seven competing regions.** Back, Close, History, the elsewhere pill and the job ticket at top left. Panel toggle, Cancel and Take over, the counter, the floor stats, plan usage and the side panel at top right. Step bar, end card and composer at the bottom. In `office.gif` the robots, which are the hero, fill less than half the frame and the corners are busy. | `OfficeOverlay`, `Docs/Media/office.gif` | B |
| 6 | **The same numbers appear in four forms.** Plan usage is `UsageHUD` at every level. Spend and tokens are `VitalsStrip` (city and building), `CounterCard` (floor) and `FloorStats`. Each is a different container with a different layout. | `StatusViews.swift`, `OfficeView.swift:560` | B |
| 7 | **Navigation grammar changes at every level.** City has a wordmark and "New project…". Building has "City" back, a title, "New floor…". Floor has the floor name as the back button. Escape means "up one level" in one place and "back to floor" in another. | `CityHUD`, `BuildingHUD`, `OfficeOverlay` (three `.keyboardShortcut(.escape)` sites) | B |
| 8 | **Overlays don't share one safe area.** The panel width is subtracted by hand in five places (`trailingInset`, `padding(.trailing…)`, `excludedTrailing`). Each new overlay repeats this. | `OfficeOverlay`, `WorldView`, `SceneControls` | B |
| 9 | **No glance mode.** The window looks the same whether the user is driving it or it's on a second monitor. There is no state that drops the chrome and enlarges what matters. | n/a | B |
| 10 | **Attention escalation is a single step.** Blocked triggers a notification and a badge once. Nothing changes if you ignore it for 10 minutes. | `Attention.needsInput` | B |
| 11 | **The welcome card explains the concept in prose.** It's a paragraph on a glass card over a very good scene (the city reel). | `TitleHUD` | C |
| 12 | **Numbers are set in the display font's proportional digits.** Counters and clocks jitter as they tick. `Typography.number` exists, so check it uses tabular figures. | `Typography.number` | C |

**What the audit didn't find, and that we keep:** the robot cast and face set, real-event-driven motion, the critically damped camera, the desk-side request cards (`DeskRequestLayer`), keyboard shortcuts on every request, Reduce Motion everywhere, the token-driven brand system, honest live-versus-final cost figures.

---

## 3. Principles

Ranked. When two conflict, the higher one wins.

1. **Signal before spectacle.** State that needs a human beats any decoration. Charm fills the gaps between signals and never masks them.
2. **One vocabulary.** A state has one name, one symbol, one colour role and one motion, wherever it appears.
3. **The world is the display, the HUD is the legend.** Status is readable on the buildings, floors and robots themselves. Text confirms it and never carries it alone.
4. **Age matters.** Anything waiting on the user shows how long it has waited.
5. **Same place, every level.** Where I am, what needs me, what it costs and what I can do sit in the same screen regions at every zoom level.
6. **Quiet by default, loud by escalation.** Start calm. Get louder only as a blocked item ages, and stop the moment it's handled.
7. **Never fake activity.** Ambient life fills idle time only, and yields the instant a real event arrives. (Kept from the game review.)
8. **Every signal has a second channel.** Never colour alone: shape, position or motion too, and a text label for VoiceOver.

---

## 4. Concept: an instrument city

Two ideas do most of the work.

### 4.1 One attention language

Six states, in priority order. This replaces `RoomState`, the `(working, waiting)` tuple and the `unseen` bool at the *display* layer. (The stored data is unchanged.)

| Priority | State | Meaning | Symbol (SF) | Colour role (existing token) | World expression | Sound |
|---|---|---|---|---|---|---|
| 1 | **Blocked** | A robot has a question or approval waiting | `hand.raised.fill` | `manager` | Hand up and "?" face; hand balloon over the storey and the building | soft "boop" |
| 2 | **Failed** | The job ended in error and you haven't looked | `exclamationmark.triangle.fill` | `error` | Red folder held up with "× ×" face; red pennant on the roof | dry low tone |
| 3 | **Ready** | A job finished and its result is unopened | `tray.full.fill` | `primaryFill` | Delivered folder in the tray; green pennant on the roof | bell |
| 4 | **Working** | A job is running and nobody is blocked | `bolt.fill` | `folder` (warm amber, existing prop token) | Windows lit; robots animate | none (optional keyboard loop) |
| 5 | **Queued** | Jobs waiting behind a busy floor | `clock.fill` | `muted` | Small paper stack on Reception | none |
| 6 | **Quiet** | Nothing to report | none | none | Lights low, idle routines | none |

Rules:
- A floor, building or the city shows the **highest-priority state present**, plus a count of that state. It never shows a mix.
- **Blocked** and **Failed** are the only two that demand action. Ready is a soft prompt and can be batched.
- Priorities are enforced in one function, so no view sorts states itself.

### 4.2 Three depths of engagement

| Mode | When | What changes |
|---|---|---|
| **Glance** | Window unfocused, on a second monitor, or the user chose it | All chrome hidden except the *dispatch rail* (below). Camera does a slow orbit that pauses on the highest-priority item. Status text at about 2× size. A blocked item's building gets a light beam. Nothing is clickable except the rail, and any click or keypress returns to Work. |
| **Work** | The default | Breadcrumb top left, instruments top right, dispatch rail bottom left, actions bottom centre. Panels closed until asked for. |
| **Focus** | A robot or desk is selected | The desk card is the only overlay. The camera frames the desk inside the current safe area. Esc goes back up one level. |

### 4.3 Semantic zoom: what each level is for

| Level | The question the user is asking | Hero | Allowed chrome |
|---|---|---|---|
| **City** | "Is anything wrong, anywhere?" | Building silhouettes with a state lamp each | Breadcrumb, city instruments, dispatch rail, New project |
| **Building** | "Which floor?" | The tower with an edge glow per floor state | Breadcrumb, building instruments, dispatch rail, Reception composer |
| **Floor** | "What's it doing, and does it want me?" | Robots at desks | Breadcrumb, floor instruments, dispatch rail, job ticket, action strip |
| **Desk** | "What exactly does it need?" | One robot and its card | Desk card only, plus breadcrumb |

Rule: the chrome allowed at a level is **all** the chrome at that level. Anything else (history, kit, tools, raw log) is a drawer opened on purpose.

---

## 5. Information architecture and layout

### 5.1 One frame for every level

```
┌───────────────────────────────────────────────────────────────┐
│ ① Where I am                              ② Instruments      │
│ City › Acme › Feature: login              ● 2 blocked  $0.42 │
│                                                                │
│                     (hero region:                              │
│                      the world, unobstructed)                  │
│                                                                │
│ ③ Dispatch rail                          ④ Primary action     │
│ ✋ Build · 4m  ✋ Review · 40s              [ Ask Reception… ]  │
└───────────────────────────────────────────────────────────────┘
                                    drawer (⑤) slides in from the right on demand
```

1. **Breadcrumb (top left).** `City › Building › Floor › Desk`. Every segment is a button. It replaces the back button, the floor-name-as-back-button and the "City" pill. **Esc always goes up one level**, and a single handler owns it.
2. **Instruments (top right).** One component, `Instruments(scope:)`. It shows the state count for the scope in the priority order above, then **spend and plan usage** in one compact group. It replaces `VitalsStrip`, `CounterCard`, `FloorStats` and the standalone `UsageHUD`. Detail (ledger, stats, trend) opens as a drawer from it.
3. **Dispatch rail (bottom left).** A horizontal list of everything Blocked, Failed or Ready across the *whole city*, most urgent first, oldest first within a state. Each chip is a symbol, a name (`Build`, or `Acme · Review`) and an age (`4m`). Click, or press ⌘J, to go to it. It is present at every level, in the same place, and replaces `NeedsYouList`, `ElsewhereNeedsYou` and part of `SinceYouLeftNote`.
4. **Primary action (bottom centre).** Whatever the level's one job is: ask Reception (building), job composer (floor), Allow (desk). Everything else goes in a menu.
5. **Drawer (right).** Activity, Room, Tools & skills, History. Closed by default, `⌘\` toggles. Opening it shrinks the *safe area*, and the camera reframes for it (5.2).

### 5.2 One safe area

Add a single `SceneSafeArea` value (insets for each edge) that the frame owns. The camera framing, `SceneControls` exclusion and every overlay read from it, and none of them compute `panelWidth + 20` themselves. That removes the five hand-maintained sites in finding 8 and makes every future overlay correct by default.

### 5.3 Navigation

| Action | Input |
|---|---|
| Up one level | Esc, or click a breadcrumb segment |
| Go to next item needing me | **⌘J** (Blocked, then Failed, then Ready; oldest first) |
| Go to city | ⌘0 (unchanged) |
| Answer or approve | ⌘1 to ⌘9, ⌘↩, ⌘⌫ (unchanged) |
| Toggle drawer | ⌘\ (unchanged) |
| Toggle Glance mode | ⌥⌘G *(needs approval)* |

Menu bar extra, Dock badge and notifications use the same states. The **Dock badge counts Blocked only** *(needs approval)*, so a badge means "something is stuck on you now". Ready and Failed show in the rail and the menu bar.

---

## 6. Screen specifications

### 6.1 City

- **Buildings carry state.** Lit windows on Working floors. A **lamp** on the roof (or above the door) in the state colour for the building's highest priority. Blocked adds a hand balloon that bobs. Failed adds a red pennant. Ready adds a green pennant. From across the room, a building that needs you looks different from one that doesn't, before any text is read.
- **Beacons and labels.** Building name on hover or when its state isn't Quiet. Never "· 0 floors".
- **Instruments.** State counts for the city, plus today's spend and plan usage.
- **Rail.** As 5.1. When empty it shows nothing at all, not an empty-state sentence. Calm is the signal.
- **Empty city / first run.** See 6.5.

### 6.2 Building

- **Tower.** Each storey has a state edge (the current open-floor glow generalised: the glow colour is the storey's state, and the open floor gets a brighter, wider edge).
- **Floor labels** move from a list at the corner to the storeys themselves (name, state symbol, age). `FloorList` becomes the keyboard and VoiceOver path only.
- **Reception composer** stays at the lobby as a speech bubble. The button label stays "Start job".
- **Since you left** folds into the rail: Ready and Failed chips, which is what the note already lists.

### 6.3 Floor

- **Hero region.** The robots get the frame. The rectangle they must occupy is at least 60% of the window height when the drawer is closed *(needs approval)*. Everything in sections 5.1 ② to ④ sits in the margins around that.
- **Job ticket** stays, but collapses to one line ("Add a sign-in page…") until hovered or clicked. It expands into the drawer's first tab.
- **Action strip.** While running: `Cancel`, `Take over`. Ended: the delivery card. Idle: the composer. One at a time, never stacked.
- **Staff strip** (revive the dormant `StepBar`, `OfficeView.swift:609`). Each step is the robot's portrait plus a state ring and an age. Blocked ones pulse. Click focuses the desk.
- **Delivery.** The end card becomes the Ready state's detail: summary, files, cost line, follow-up. It collapses to the rail's Ready chip once seen.
- **Failure.** Same card, red, with one primary button (Try Again or Open Usage Settings) and no follow-up field for account-level failures.

### 6.3.1 Desk (focus)

The desk request card is already in-world (`DeskRequestLayer`). Keep it. Add **age** ("Waiting 2m") to its header and a **"1 of 2" chip** to step to the next blocked desk, so that two blocked robots don't hide each other.

### 6.4 Reception and hiring

Out of scope for this pass beyond the shared frame. The hiring panel keeps its layout and adopts the breadcrumb and safe area.

### 6.5 First run

Keep the empty lot, the receptionist and the "For sale" sign. Replace the paragraph with **one line and one button**: "Every project is a building." and "Break ground on your first project…". "Watch a demo" becomes a text link below. Copy needs approval.

---

## 7. Interaction model

- **Every state is reachable three ways:** in the world (click), from the rail (click or ⌘J), from the keyboard (⌘J, arrows). VoiceOver gets the rail as a labelled list and the current level as an "Office floor" group, as today.
- **Hover** shows a state chip with the age, and for a blocked robot the first line of its question. It never changes layout.
- **Click on an empty region of the world** does nothing, except in Glance mode where it returns to Work. There is no accidental navigation.
- **Camera** rules:
  - The camera never moves on its own while the user is dragging or has used the keyboard in the last 3 seconds *(needs approval)*.
  - A newly Blocked item does not steal the camera. It adds a rail chip and a world signal. Only ⌘J or a click flies there. (Today's auto-glide to a robot that raises a hand is kept only when the floor is already open and nothing else is selected.)
  - Big moves keep the existing arc-and-settle flight.
- **Undo for navigation:** ⌘[ returns to the previous camera location, so ⌘J is safe to press. *(needs approval)*

---

## 8. Motion language

Three tiers, each with a job. All numbers are proposals *(needs approval)* unless marked *existing*.

| Tier | Job | Duration | Curve | Examples |
|---|---|---|---|---|
| **Ambient** | Life | 4 s or longer, looping | Ease in/out | Cars, clouds, idle routines, lamps breathing |
| **Response** | "I heard you" | 120 to 240 ms | Ease-out | Chip appears, stamp lands, robot hand goes up |
| **Transit** | Change of place | 450 to 900 ms *(existing camera flight: 450 ms tap, arc-and-settle)* | Critically damped *(existing)* | Camera flights, tower rise |

**Escalation ladder** for a Blocked item (Reduce Motion replaces every step's motion with the same step's static change):

| Age | Change |
|---|---|
| 0 s | Response pop: chip appears, hand up, one "boop" |
| 30 s | Slow pulse on the world signal (one pulse per 2.4 s, never faster than 3 Hz at any point) |
| 5 min | Chip turns from `manager` fill to outlined-with-badge "5m+", and a second notification is posted if the app is in the background |
| 15 min | Menu bar icon gains a dot; Dock badge stays. **No new sound.** Nagging is a failure mode. |

Only **one** thing pulses at a time: the oldest Blocked item. Everything else holds still.

---

## 9. Visual system

**Keep.** The KayKit-style world, the brand token pipeline (`Brand.swift`, `Palette`), the rounded "glass" surfaces, the brand font.

**Change.**
- **Surfaces.** Three elevations, used consistently: **Rail/Instruments** (glass, raised), **Card** (in-world, opaque enough for 4.5:1 text contrast), **Drawer** (full-height, opaque). Today everything is one glass style at different opacities. *(Radii and opacities need approval.)*
- **Numerals.** Confirm `Typography.number` sets tabular figures, so ticking counters and ages don't jitter.
- **Colour.** **No new tokens in slice 1.** The signal table maps onto existing tokens. If the audit shows `manager` and `folder` don't separate well in dark mode, we add `signalWorking` and `signalReady` to every brand together *(needs approval)*.
- **Iconography.** One SF Symbol per state, always the fill variant, always at the same weight. Symbols never appear without their state colour role or their label.
- **Density.** Rail and instrument chips: two type sizes (label and age), one baseline. No card inside a card.

---

## 10. Delivery plan

Each slice is shippable alone and leaves the app better.

| Slice | Change | Risk | Needs approval |
|---|---|---|---|
| **1 (this session)** | **Signal model.** A single `FloorSignal` type with the priority order above, derived from existing data. Use it in the city's needs-you list, so it sorts by urgency and separates Blocked, Failed and Ready with their own symbol, label and age. Add **⌘J: Next that needs you**. No layout change. Built, **not compiled or rendered** (no Swift toolchain in that session). **Age is not in slice 1:** `PendingRequest` has no timestamp, so slice 2 starts by adding one in OfficeCore. | Low | Nothing new |
| 2 | Dispatch rail at every level, replacing `NeedsYouList`, `ElsewhereNeedsYou` and `SinceYouLeftNote`. Age on desk cards. | Medium | Rail layout |
| 3 | Breadcrumb, single Esc handler, `SceneSafeArea`. | Medium | Breadcrumb layout |
| 4 | One `Instruments` component; drawer for detail. | Medium | Layout |
| 5 | Building and storey state in the world (lamps, pennants, edge colours). | Medium (RealityKit, offscreen-checkable) | Visuals |
| 6 | Glance mode and escalation ladder. | Medium | Timings, ⌥⌘G |
| 7 | First-run copy and layout. Companion: same states and rail. | Low | Copy |

The Companion shares the scene files, so slice 5 must keep them free of Mac-only types (`Docs/Companion.md`). The signal type is written with no AppKit so the phone can use it in slice 7.

---

## 11. Validation

**Before building past slice 2, confirm with renders:** offscreen renders of city, building and floor in light and dark with a blocked floor and a ready floor, checked against findings 4, 5 and 12. (`-render-preview`, see `CLAUDE.md`.) If a finding doesn't hold, strike it here.

**Tests with 5 developers, 2 tasks each, on a real or replayed multi-floor stream (`make replay`):**

| Task | Measure | Target |
|---|---|---|
| Glance test: 5 s look at the city, then answer "is anything waiting on you, and where?" | Correct answers | 5 of 5 |
| A second floor becomes blocked while the user is on another floor. Say when you notice. | Time to notice, without sound | Under 10 s |
| Answer a blocked approval from anywhere | Time from noticing to answered | Under 15 s |
| "Which of these has been waiting longest?" | Correct, without opening anything | 5 of 5 |
| Leave for 30 minutes, return | Time to recount what happened | Under 30 s |

**Success is** fewer missed approvals in a week of real use (the app already records job outcomes, so we can count Blocked items that waited over 5 minutes before and after slice 2).

**Accessibility checks each slice:** VoiceOver reads the rail in priority order with state and age; every state has a second channel; Reduce Motion replaces pulses with static changes; text over glass meets 4.5:1 in both themes; the whole flow works keyboard-only.

---

## 12. Decisions needed from the owner

1. Approve the six-state vocabulary, its priority order and its use of existing colour roles (section 4.1).
2. Dock badge counts **Blocked only**, or everything as today (5.3).
3. The 60% hero rule for the floor screen (6.3).
4. Camera doesn't steal focus for new Blocked items when you're elsewhere (7).
5. Escalation timings 30 s, 5 min and 15 min (8).
6. ⌥⌘G for Glance mode (5.3), and whether Glance should exist on the phone.
