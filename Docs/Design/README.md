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
| **1 (merged)** | **Signal model.** A single `FloorSignal` type with the priority order above, derived from existing data. Use it in the city's needs-you list, so it sorts by urgency and separates Blocked, Failed and Ready with their own symbol, label and age. Add **⌘J: Next that needs you**. No layout change. Built, **not compiled or rendered** (no Swift toolchain in that session). **Age is not in slice 1:** `PendingRequest` has no timestamp, so slice 2 starts by adding one in OfficeCore. | Low | Nothing new |
| **2 (built)** | `PendingRequest.since` in OfficeCore, age on desk cards, longest-waiting first within a state, appearing after 30 s. Ready and failed floors record when they finished unseen (`Floor.unseenSince`), so they show an age and sort oldest first too. The dispatch rail at every level (10.2). | Medium | Settled (10.2) |
| **3 (built)** | Breadcrumb, single Esc handler, `SceneSafeArea` (10.3). | Medium | Settled (10.3) |
| **4 (built)** | One `Instruments` component, with each segment's detail in a popover (10.4). | Medium | Settled (10.4) |
| **5 (checked)** | Building and storey state in the world (lamps, pennants, edge colours). | Medium (RealityKit, offscreen-checkable) | Settled (10.1) |
| **6 (built)** | Glance mode and escalation ladder (10.5). | Medium | Settled (10.5) |
| 7 | First-run copy and layout. Companion: same states and rail. | Low | Copy |

The Companion shares the scene files, so slice 5 must keep them free of Mac-only types (`Docs/Companion.md`). The signal type is written with no AppKit so the phone can use it in slice 7.

### 10.1 Slice 5 spec

Everything here is decided; the builder needs no further design judgement. Line numbers are at `b8d5f99`. Scene units: a city building is 1.4 wide and 1.14 deep (`Facade.cityScale`, `App/Facade.swift:18`), each storey 0.35 tall, and the overview camera shows about 50 px per unit in a 1600 × 1000 render. Every visual reads its state from `FloorSignal`; no scene decides state itself.

**What this changes from the plan above.**
- **Ready is `grass`, not `primaryFill`.** In The City brand `primaryFill` (#F2C14E) is almost the same yellow as `folder` (#FAC740), so Ready and Working would look alike. In Alphero `primaryFill` *is* `manager` (#3D2051), so Ready and Blocked would look alike. `grass` is an existing token in both brands, is green (which 4.1 and 6.1 already describe), and differs from every other signal colour. No new token.
- **`FloorSignal` isn't phone-safe yet.** Section 10 says it has no AppKit, but `App/FloorSignal.swift:1` imports AppKit and the file isn't in the companion's sources. Step 1 fixes that.
- **The balloon already exists and is too small.** `CityScene` has a `manager` sphere (radius 0.14, about 14 px) on a string, shown for any "needs you", including unseen results (`App/CityScene.swift:191-199`, `:594`). That's why finding 4 holds. It's replaced, not added to.
- **Storey labels re-invent state.** `refreshLabels` (`App/BuildingScene.swift:687-712`) counts an unseen result as "Needs you ✋" and colours Working `primaryFill`. It moves onto `FloorSignal`.
- **Bob and pulse.** Section 8 says "everything else holds still", while 6.1 says every balloon bobs. Resolved as: the bob is ambient (a 4 s loop, allowed by the Ambient tier), and only the single oldest Blocked item *pulses* (grows and shrinks).

#### Step 1: shared signal type and data

| Change | Where |
|---|---|
| Replace `import AppKit` with `#if os(macOS) import AppKit #else import UIKit #endif`, and add `- App/FloorSignal.swift` to `TheCityCompanion` sources after `App/Billboard.swift`. Run `make project`. | `App/FloorSignal.swift:1`, `project.yml:87` |
| `.ready` colour becomes `Palette.grass`. | `App/FloorSignal.swift:36` |
| Add `var glyph: NSColor`, the colour of the symbol drawn on a filled signal shape: blocked and failed `Palette.textOn(colour)`; working `Palette.resolved(Palette.text, dark: false)` (dark in both brands and themes, since `folder` is light in both); ready `Palette.text`; queued and quiet `Palette.textOn(Palette.muted)`. | `App/FloorSignal.swift`, after `colour` |
| Add `static let pulseAfter: TimeInterval = 30`, `static let pulsePeriod: Double = 2.4`, `static let pulseGrowth: Float = 0.18`, and `static func pulse(_ t: Double, still: Bool) -> Float`, returning `1 + pulseGrowth` when `still`, else `1 + pulseGrowth / 2 * (1 + cos(2π t / pulsePeriod))`. It starts at full size, so the Reduce Motion hold is the pulse's peak. | `App/FloorSignal.swift`, after `ageAppearsAfter` (`:62`) |
| `RoomState.colour` returns `FloorSignal.blocked.colour`, `.working.colour` and `.quiet.colour`, so the room counts inside a label match the label (Working chips turn from `primaryFill` to `folder`). Its only use is `BubbleView`. | `App/Billboard.swift:239-245` |
| `BubbleView` gains `var glyph: NSColor? = nil`, drawn as `glyph ?? Palette.textOn(colour)` and added to `billboardKey`. | `App/Billboard.swift:152-192` |
| `OfficeScene.reduceMotion` also returns true when the launch arguments contain `-reduce-motion`, so renders can check the static replacements. | `App/OfficeScene.swift:67-73` |
| `Storey` gains `var waitingSince: Date? { get }`. `RunController` returns `state.pendingRequests.map(\.since).min()`, and `PhoneStorey` returns `nil` (`QuestionSnapshot` has no date; the phone's ages are slice 7). | `App/BuildingScene.swift:12-17`, `App/CityStore.swift:634-636`, `Companion/PhoneCity.swift:8-14` |
| `TowerPlan.Floor` gains `var unseenSince: Date?` and `var queued = 0`. `Building.plan` fills them from `unseenSince` and `queued?.count ?? 0`. The phone's `PhoneCity.plan` leaves the defaults. | `App/BuildingScene.swift:21-26`, `App/CityStore.swift:639-641`, `Companion/PhoneCity.swift:128-133` |
| In `BuildingScene.swift`, `extension TowerPlan.Floor { func signal(_ storey: (any Storey)?) -> FloorSignal }` calls `FloorSignal.of(pending: storey?.waitingCount ?? 0, unseen: unseen, outcome: lastOutcome, running: storey?.isRunning == true, queued: queued)`, plus `func since(_ storey:) -> Date?` (blocked: `storey?.waitingSince`; failed and ready: `unseenSince`; otherwise nil). Same rule as `CityStore.signal(of:)`, through the same function. | `App/BuildingScene.swift`, after `TowerPlan` |
| `floorsNeedingYou()` becomes `floorsNeedingYou(in buildings: [Building]? = nil)`, using `buildings ?? self.buildings`. Add `pulsingFloor(in buildings: [Building]? = nil, now: Date = .now) -> UUID?`: the first `.blocked` item of that list if `now − since ≥ FloorSignal.pulseAfter`, else nil. The list is already oldest-first, so this is the one pulse. | `App/CityStore.swift:472-486` |
| Add `signal(of building: Building) -> (signal: FloorSignal, count: Int, since: Date?)`: the lowest `signal(of:)` across its floors (`.quiet` for an empty lot). `count` is the number of pending requests on its blocked floors when Blocked, otherwise the number of floors in that state. `since` is the oldest `since` among those floors, worked out as in `floorsNeedingYou`. | `App/CityStore.swift`, after `:461` |
| `BuildingScene` gains `var pulsingFloor: () -> UUID? = { nil }`. The Mac `show` extension sets it to `{ CityStore.shared.pulsingFloor() }`. | `App/BuildingScene.swift:55-56`, `App/CityStore.swift:646-650` |

#### Step 2: the city (`App/CityScene.swift`, Mac only)

Each building gets one **marker** entity in place of `beacon`, at the roof centre `(x, top, z)`, where `top = bounds.max.y` (`:193`). `Lot` (`:51-65`) keeps `top`, `marker`, `balloon` (the moving part) and `signal`. Build parts with `ModelLibrary.box` and `ModelLibrary.material`, and signs with `Billboard.make`, so all are cached. Rebuild the marker's children only when the building's signal changes.

| State | Lamp | Above the lamp | Label |
|---|---|---|---|
| Blocked | `manager`, glowing | **Balloon**: string, then the hand badge; bobs | always shown |
| Failed | `error`, glowing | **Pennant** on a pole: `exclamationmark.triangle.fill` on `error` | always shown |
| Ready | `grass`, glowing | **Pennant** on a pole: `tray.full.fill` on `grass` | always shown |
| Working | `folder`, glowing | nothing (the windows are already lit, `:494`) | always shown |
| Queued | `muted`, not glowing | nothing | always shown |
| Quiet | none | nothing | on hover only (as today) |

Sizes, in city units above `top`:

| Part | Geometry | Centre |
|---|---|---|
| Lamp | `box(width: 0.24, height: 0.1, depth: 0.24, cornerRadius: 0.05)`, `material(colour, roughness: nil, emissive: 2)`, or `emissive: 0` for Queued. 2 is the tower's existing `highlightGlow`. | + 0.05 |
| Balloon string | `box(width: 0.012, height: 0.7, depth: 0.012)` in `Palette.text`, as today's string | + 0.45 |
| Balloon badge | `SignalBadgeView(signal: .blocked)` billboard, scale 0.7 (0.86 units, about 44 px, against today's 14 px sphere) | + 1.23 |
| Pennant pole | `box(width: 0.03, depth: 0.03)` in `Palette.text`, from + 0.1 to 0.06 above the pennant's top edge | halfway along it (spans 0.1 to about 1.45) |
| Pennant | `SignalPennantView(signal:)` billboard, scale 0.32 (about 44 px tall), bottom edge at + 0.5 so about 10 px of pole shows above the lamp | + 0.5 + half its height |
| Label (`lot.root`) | unchanged `BubbleView` at scale 0.5 | + 2.4 with a balloon or pennant, + 0.75 otherwise (today's height) |

New views in `App/Billboard.swift`, both `BillboardKeyed` on the signal and its colours (`colour.key(dark:)`):
- `SignalBadgeView`: `Image(systemName: signal.symbol)` at `.system(size: 36, weight: .semibold)` in `signal.glyph`, on a 64 pt `Circle` in `signal.colour` with a 2 pt `Palette.hairline` border. This is `BubbleView`'s leading circle (`:164-168`) at twice the size.
- `SignalPennantView`: the symbol at `.system(size: 40, weight: .bold)` in `signal.glyph`, `.padding(.top, 22)`, `.padding(.bottom, 58)`, width 96, on the existing `Pennant()` shape (`:126-139`) filled with `signal.colour`. This is `BannerView` (`:102-124`) without the title.

Behaviour:
- `refresh()` (`:584-613`) uses `city.signal(of: building)` for the label's symbol, colour and glyph, and stops using `status(of:)`. Text: `"\(name) · \(signal.label(count: count))"`, plus `" · \(FloorSignal.age(...))"` for Blocked, Failed and Ready once `since` is at least `ageAppearsAfter` old. Quiet keeps today's `statusLine(for:)` ("Empty lot", "3 floors · all quiet"). Between 30 s and 60 s the text changes every second; that's at most 30 billboard renders per building, which is acceptable.
- Visibility, in `setLabelsVisible` (`:283`), `hover` (`:476`) and `refresh`: label `labelsVisible && (hovered == id || signal != .quiet)`; marker `labelsVisible && signal != .quiet`. So both hide on entering a building (`App/World.swift:66`) and return on leaving (`:113`).
- The window glow (`lot.working`, `lotGlow`) stays tied to "any floor running", even under a higher state. It shows activity, not status.
- `closeUpPose` (`:289`) targets `[x, top − 1.0, z]`, where it aims today.
- Remove the `beacon` sphere and its `generateSphere` call.

#### Step 3: the tower (`App/BuildingScene.swift`, shared with the phone)

**State edge.** The open-floor glow (`mark`, `:468-483`) becomes a frame on every storey that isn't Quiet, and on the open storey whatever its state. `highlight` (`:62`) becomes `edges: [UUID: (entity: Entity, key: String)]`, rebuilt in the labels' one-second pass and keyed on `"\(signal)|\(open)"`. The geometry is today's four strips at slab height.

| | Colour | Strip width | Emissive |
|---|---|---|---|
| Open storey | `signal.colour` (`muted` if Quiet) | 0.3 (twice `highlightWidth`) | 2 (`highlightGlow`) |
| Other storey, not Quiet | `signal.colour` | 0.15 (`highlightWidth`) | 1 |
| Other storey, Quiet | no edge | | |

Add `static let edgeGlow: Float = 1` beside `highlightWidth` and `highlightGlow` (`:110-111`). Hook points: clear `edges` where `labels` and `highlight` are cleared on a rebuild (`:133-138`); `enter(floor:)` (`:456`) and `leaveFloor()` (`:607-608`) refresh the edges in place of `mark` and removing `highlight`; `reveal(through:)` (`:461-466`) enables an edge like its `fitOut`; `hideStoreysForLobby` (`:527`) adds the edge to the parts it makes transparent.

**Storey labels.** `refreshLabels` (`:687-712`) uses `floor.signal(session)` and `floor.since(session)`: symbol `signal.symbol`, circle `signal.colour`, glyph `signal.glyph`, text `"\(floor.name) · \(signal.label(count:))"` plus the city's age suffix. The count is `session.waitingCount` when Blocked, otherwise 1. "Needs you" and "Done" go: a finished, seen floor reads "Quiet", an unseen one "Ready". Add the age string to the label key. The label is the storey's hand balloon; nothing else goes over the storey.

#### Step 4: motion

| What | Motion | Reduce Motion |
|---|---|---|
| Blocked balloon (city) | Bob: `balloon.position.y = top + 1.23 + 0.04 · sin(2π · clock / 4)`, replacing `sin(clock * 2) * 0.06` at `:568-573` | Still at `top + 1.23` |
| The single pulse, city | If `pulsingFloor(in: buildings)` is a floor of this building, the badge (not the string) scales by `FloorSignal.pulse(clock, still: false)` | Held at 1.18× |
| The same pulse, tower | If `pulsingFloor()` is one of the storeys, that label scales by `1.3 × FloorSignal.pulse(pulseClock, still: false)`; add `pulseClock`, advanced in `update` (`:652`) | Held at 1.3 × 1.18 |
| Lamps, pennants, edges | Still | Still |

City markers hide on entering a building, so there is only ever one pulse on screen. Write the scale only when it changes (`.claude/rules/app.md`). On the phone `pulsingFloor` stays nil, so nothing pulses there yet.

#### Step 5: accessibility

| State | Colour | Second channel |
|---|---|---|
| Blocked | `manager` | Round balloon on a string, bobbing; hand glyph; the only thing that pulses |
| Failed | `error` | Swallowtail pennant on a pole; triangle glyph |
| Ready | `grass` | Swallowtail pennant on a pole; tray glyph |
| Working | `folder` | Lamp, lit windows, bolt glyph in the label |
| Queued | `muted` | Unlit lamp; clock glyph in the label |
| Quiet | none | No lamp or marker; label on hover only |

Failed and Ready share a shape; their glyphs tell them apart and the label names them. VoiceOver has no path through the world, so the words go on the existing keyboard lists: `ProjectList`'s symbol and `accessibilityLabel` (`App/CityViews.swift:134-146`) and `FloorList`'s symbol and `floorStatus` (`:467-472`, `:500-506`) use the signal's symbol and `label(count:)`, plus "waiting 4 minutes" once past `ageAppearsAfter`. Glyphs need 3:1 on their fill; `glyph` is chosen for that, and the renders below check it.

#### Step 6: renders

`-city` builds its own five sample buildings (`App/OffscreenRenderer.swift:132-161`), and the tower uses `buildings[0]`. Today's seed gives one Blocked floor (Security review), two Working floors and a Docs floor that is only Quiet. There's no Ready or Failed floor, and the request's age is zero, because `PendingRequest.since` is the real `Date()` (`Packages/OfficeCore/Sources/OfficeCore/OfficeReducer.swift:128`), not the renderer's clock. Seed as follows:

- `buildings[0].floors[2]` (Docs, `:159`): add `unseen: true, unseenSince: .now - 900`. Ready, 15m.
- `buildings[2].floors = [.init(name: "Payments", hires: ["build", "review"], budgetUSD: 1, lastOutcome: "failed", unseen: true, unseenSince: .now - 300)]`. Failed, 5m.
- `buildings[3].floors = [.init(name: "Changelog", hires: ["research", "review"], budgetUSD: 1)]`, and in `seedStatus` (`:256-260`), under `floors.count > 5`, play `approval-requests.jsonl` for 12 lines on `floors[5]`. A second Blocked building.
- Add `RunController.backdateRequests(to: Date)`, which sets every pending request's `since` (`state` is `private(set)`, `App/RunController.swift:131`). Call it with `.now - 240` on `floors[1]` (Security review: 4m, pulses) and `.now - 45` on `floors[5]` (Changelog: 45s, shows an age, doesn't pulse).
- After `tower.show` (`:207`), set `tower.pulsingFloor = { CityStore.shared.pulsingFloor(in: buildings) }`, since the preview's buildings aren't in the store.

That gives theCity Blocked (pulsing), alphero-web Working, client-portal Failed, docs-site Blocked (still) and infra Quiet. Run `make build`, then these from the repo root (no `timeout` on this Mac), and `sips -Z 1000` each file before viewing:

```
B=build/Build/Products/Debug/TheCity.app/Contents/MacOS/TheCity
W="$PWD/SampleWorkspace"
$B -render-preview /tmp/s5-city-dark.png  -theme dark  -workspace "$W" -city
$B -render-preview /tmp/s5-city-light.png -theme light -workspace "$W" -city
$B -render-preview /tmp/s5-city-still.png -theme dark  -workspace "$W" -city -reduce-motion
$B -render-preview /tmp/s5-tower-dark.png  -theme dark  -workspace "$W" -building
$B -render-preview /tmp/s5-tower-light.png -theme light -workspace "$W" -building
$B -render-preview /tmp/s5-open-blocked.png -theme dark -workspace "$W" -building -floor 1
$B -render-preview /tmp/s5-open-ready.png   -theme dark -workspace "$W" -building -floor 2
```

| Render | Must show |
|---|---|
| `s5-city-dark`, `s5-city-light` | Four labels without hovering: "theCity · Waiting · 4m" (hand, `manager`), "alphero-web · Working" (bolt, `folder`), "client-portal · Failed · 5m", "docs-site · Waiting · 45s". infra has no label, lamp or marker. Balloons over theCity and docs-site, theCity's visibly larger (the city render stops at 0.5 s, where the pulse is 1.11×). A red pennant over client-portal. Lamps in `manager`, `folder`, `error`, `manager`. No pink sphere anywhere. Every glyph readable on its fill. |
| `s5-city-still` | As dark, but theCity's badge is exactly 1.18× docs-site's, and both balloons sit at the same height above their roofs. |
| `s5-tower-dark`, `s5-tower-light` | Edges: Feature: login `folder`, Security review `manager`, Docs `grass`, all 0.15 wide. Labels "Feature: login · Working", "Security review · Waiting · 4m", "Docs · Ready · 15m". No "Needs you" or "Done". |
| `s5-open-blocked` | Security review's edge `manager` at 0.3 wide; Docs, above it, hidden along with its edge. |
| `s5-open-ready` | Docs's edge `grass` at 0.3 wide; the lower storeys' edges still 0.15. |

Also run `make test` (OfficeCore is unchanged) and **`make companion`**, which proves `FloorSignal.swift`, `Billboard.swift` and `BuildingScene.swift` still compile for iOS. There's no render argument for the brand, so check Alphero's glyph contrast in the live window (`Tools/Dev/relaunch.sh`, then switch brand in Settings).

### 10.2 Dispatch rail

Decided with the owner on 2026-09-30. It uses existing styles and values only.

- **One view.** `DispatchRail` (`App/CityViews.swift`) replaces `NeedsYouList` (city), `ElsewhereNeedsYou` (floor) and `SinceYouLeftNote` (building). `WorldView` mounts it once, bottom left with the HUDs' 20 pt margin, so it's in the same place at every level.
- **Bottom row, lifts the rest.** When it has chips, everything anchored to the bottom (`ProjectList`, the Reception composer and hiring panel, `FloorList`, the floor's action strip and desk cards) moves up by the rail's height plus the HUDs' 12 pt stack gap, passed down as the `railInset` environment value. An empty rail shows nothing and moves nothing. This is the first piece of `SceneSafeArea` (slice 3).
- **Contents.** `floorsNeedingYou()`, so Blocked, then Failed, then Ready, oldest first, minus the open floor. Hidden on the title screen, on a focused desk and in the kiosk (4.3: the desk card is the only overlay).
- **Chip.** The accent pill already used for these items: `PillButtonStyle(.accent(signal.colour))`, the signal's symbol, the name (the floor alone inside its own building, otherwise `Building · Floor`), then the age in `Typography.caption` with tabular digits once it passes `ageAppearsAfter`. The chips sit in `ProjectList`'s pill bar (glass, radius 24, padding 5, spacing 8). Help text gives the full name and state, plus "(⌘J)" on the first chip. VoiceOver reads a "Needs you" group, with each chip read as "building, floor, state, waiting 4 minutes".
- **Overflow.** One line, never wrapped. As many chips as fit, then a secondary `+N` pill whose menu lists the rest. On a floor with the side panel open, the rail stops 20 pt short of the panel.

### 10.3 Breadcrumb, Esc and safe area

Decided with the owner on 2026-09-30. It uses existing styles and values only.

- **Breadcrumb** (`App/Frame.swift`). Top left at every level, in place of the "‹ City" pill, the floor-name back pill and the desk's "Back to floor" pill. The segments come from the route: the compact wordmark (home), then the building, the floor, and the desk (the robot's name). Every segment but the last is a button in `muted`. The current one is plain text in `text`. They sit in one glass capsule, the rail's surface (`Glass`, radius 24, no padding), with `SegmentStyle` segments (moved from `OpenInMenu` into `Theme.swift`) and muted chevrons. On the city the breadcrumb is just the wordmark, as before. The new-floor flow reads `Building › New floor`.
- **Narrow windows.** The building's top row tries the full wordmark first, then drops the wordmark to its symbol if the row doesn't fit (`Breadcrumb.compact`, `Wordmark(symbolOnly:)`).
- **Building title.** The name is in the breadcrumb only. The "Swipe up or down…" hint stays.
- **Floor menu.** History and Close floor move into a `…` secondary pill menu after the breadcrumb. ⌘Y still opens History from the menu bar.
- **Esc.** One hidden button in `WorldView` runs the segment one level above the current one (`Breadcrumb.up`): desk → floor → building → city, and New floor → building. It's disabled in the kiosk. The other `.escape` shortcuts are gone (building back, floor back, desk back, `HiringView` back). It works out "up" at the moment you press it, because a shortcut kept an earlier render's action and jumped two levels.
- **`SceneSafeArea`.** `WorldView` works it out once (the side panel's width on the trailing edge, the rail on the bottom) and passes it down in the environment. The camera's `trailingInset`, `SceneControls.excludedTrailing`, the floor overlay's trailing padding and the rail all read from it. It replaces `railInset`. `OfficeView`, which is never created, still works it out by hand.
- **Plan usage (slice 4, early, at the owner's request).** `UsageHUD` is one row: for each account, its name (shown only when there's more than one account), then Session and Week as the existing ring with a percentage. Reset times go in the hover help. Clicking opens the old full panel (`UsageDetail`: reset times, "as of", refresh) in a popover. The floor no longer squeezes it to the panel's width.

### 10.4 Instruments

Decided with the owner on 2026-09-30.

- **One component** (`App/Instruments.swift`), top right at every level, in place of `VitalsStrip`, `CounterCard`, `FloorStats` and the standalone `UsageHUD`. It is one glass capsule (radius 24) with two segments split by a hairline: **state**, then **plan usage**. There's no spend at a glance.
- **State.** City and building count floors by `FloorSignal` (Blocked, Failed, Ready, Working, Queued; zeros hidden, "–" when all are quiet), with the same symbols and colours as the rail and the world. The segment is hidden when there are no floors. On a floor, where there's only one signal, it's the robots' `RoomTally`.
- **Detail.** Clicking a segment opens its popover, hosted on the group: the ledger (city and building), `FloorDetail` (floor: the job's clock and spend against budget or plan, tokens, context, turns, per-model figures, subagents, denials and the floor's record), or `UsageDetail`. The floor's clock and spend are no longer on screen without a click.
- **Placement.** City: between the wordmark and New project. Building: in the top row (the old Vitals strip under the hint is gone). Floor: under the Cancel / Take over row.
- **Narrow building row.** A third fallback after the logo-only breadcrumb: Open in and New floor become icon-only pills, with their names in the help text.

### 10.5 Escalation and Glance mode

Decided with the owner on 2026-09-30.

**Escalation ladder** (the timings are `FloorSignal.escalateAfter` and `nagAfter`). A 5-second timer (`CityStore.escalate`) runs it, and it skips replays.
- **0 s:** today's notification. The **Dock badge now counts Blocked requests only**, not unseen results (decision 2).
- **5 min:** the rail chip turns from `manager` fill to a clear pill with a 2 pt `manager` outline, and a `manager` "5m+" capsule replaces the age. If the app is in the background, one reminder is sent per request: "Still waiting: …", with the same body and actions.
- **15 min:** the menu bar hand becomes `hand.raised.circle.fill`, and the count stays. No new sound.

**Glance mode** (`CityStore.glance`, `CityScene.glancing`).
- **In:** ⌥⌘G (View menu), or automatically when the window has been in the background for 60 s. It isn't entered on the title screen, in New floor, in the demo or in the kiosk. It goes to the city and remembers where you were.
- **Shows:** only the dispatch rail. In-world labels are at 2×, and each Blocked building gets a beam (a 0.08 × 0.08 box, `manager`, emissive 2, 12 units tall). The camera orbits once every 120 s, and for the first 8 s of each turn it holds on the building of the most urgent floor (aimed 1.2 above its roof, pitch 0.45, distance 26). With Reduce Motion there's no orbit, and the camera holds on that building.
- **Out:** any click or key, ⌥⌘G, or the window becoming key again. That returns to where you were. A rail chip goes to its floor instead.

---

## 11. Validation

**Before building past slice 2, confirm with renders:** offscreen renders of city, building and floor in light and dark with a blocked floor and a ready floor, checked against findings 4, 5 and 12. (`-render-preview`, see `CLAUDE.md`.) If a finding doesn't hold, strike it here.

**Checked on a Mac at `e25dbdd`:** slices 1 and 2 build, and all 170 OfficeCore tests pass.
- **Finding 4 holds.** In the city render, the building with a blocked floor looks the same as the others. Light and dark city renders are also almost identical (both lit for dusk).
- **Finding 12 is struck.** `Typography.number` already uses `.monospacedDigit()`.
- **6.2 is partly done already.** The building view labels each storey in the world ("Security review · Needs you ✋ 1", "Feature: login · Working ⚡ 1", "Docs · Done"). What's missing is the state colour on the storey edge, and a Ready state that's distinct from Done-and-seen.
- **Findings 5 and 6 are unchecked.** Offscreen renders draw the scene and in-world labels but not the SwiftUI HUD, so they need a live window (`Tools/Dev/relaunch.sh`).

**Slice 5 checked on a Mac at `6486e66`:** it builds, all 170 OfficeCore tests pass and `make companion` builds. All seven renders in 10.1 step 6 match their table. Seen along the way, not caused by slice 5: in `s5-open-ready`, the "Needs approval" desk label from the storey below shows through onto Docs; in light mode the `grass` edge is pale against the pale ground.

**Slice 2's rail checked in the live window** (dev data seeded with two Failed and four Ready floors) at 1400 and 1000 pt wide: city, building and floor, and a floor with its side panel open. The order, short names and `+N` overflow are right, and everything bottom-anchored clears the rail. Already there before the rail: at 1000 pt, `FloorList` pills wrap mid-word ("Paym ents"), and on a floor with the side panel open the HUD is wider than the window and clipped at both edges. Blocked chips and the escalation to "5m+" (slice 6) are unchecked, because a Blocked floor needs a live request.

**Slice 3 checked in the live window** at 1000 and 1400 pt wide, on city, building and floor. Esc goes floor → building → city one level at a time; the first build jumped two levels, which the resolve-on-press fix above cured. The breadcrumb is readable over grass and road. The building row fits at 1000 pt with the symbol-only root. Usage fits on one line at every level, and its popover opens with the full detail. The floor menu opens. Unchecked: the desk segment and Esc from a desk (clicking a robot on an idle floor didn't select it), and Esc from New floor. `make test` and `make companion` pass.

**Slice 4 checked** in offscreen `-hud` renders (city in light and dark, building, floor with `-focus build -hud`) and in the live window at 1000 pt: the building row fits with icon-only buttons, and the ledger popover opens from the counts. The owner checked the usage popover and the floor's `FloorDetail` popover in the live window. **Found:** the Ready symbol in `grass` has too little contrast on glass in both themes (pale on pale in light, dark green on dark in dark). It needs a token decision (section 9 already anticipates `signalReady`).

**Slice 6 checked:** a `-city -hud -blocked-age 400` render in light and dark (outlined "5m+" chip), `-city -glance` renders with and without `-reduce-motion` (2× labels, beams, framing), and in the live window: ⌥⌘G in, a key out, and automatic entry after 60 s in the background, leaving on return. **Unchecked:** the reminder notification and the 15-minute menu bar icon, which need a real request left waiting.

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

## 12. Decisions

The owner delegated every decision and value in this plan on 2026-09-29, so *(needs approval)* marks above are settled as proposed unless listed here.

1. **Approved:** the six-state vocabulary, its priority order and its use of existing colour roles (section 4.1).
2. **Dock badge counts Blocked only** (5.3).
3. **Approved:** the 60% hero rule for the floor screen (6.3).
4. **Approved:** the camera doesn't steal focus for new Blocked items when you're elsewhere (7).
5. **Approved:** escalation timings of 30 s, 5 min and 15 min (8).
6. **⌥⌘G** toggles Glance mode on the Mac. There is no Glance mode on the phone for now.
7. **Order:** slice 5 next, since finding 4 is confirmed and it can be checked with offscreen renders. Then the rest of slice 2 (the rail), then 3, 4, 6 and 7.
8. **Rail (2026-09-30):** the rail is the bottom row and lifts the rest; the open floor is left out; overflow goes into a `+N` menu (10.2).
9. **Breadcrumb (2026-09-30):** wordmark root; one glass capsule; building title dropped and hint kept; History and Close floor in a `…` menu; the root drops to its symbol when the row is short (10.3).
10. **Plan usage (2026-09-30):** rings and percentages only, with detail in a popover on click (10.3).
11. **Instruments (2026-09-30):** state and usage only; floors counted by state; one popover per segment; icon-only Open in and New floor when the building row is short (10.4).
12. **Escalation and Glance (2026-09-30):** the outlined chip with a "5m+" badge; a "Still waiting" reminder; the circled hand in the menu bar; Glance also starts after 60 s in the background (10.5).
