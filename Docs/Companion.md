# The City on iPhone

A companion app for glancing at your agents away from the desk. It shows one building at a time in 3D, with a glass banner along the bottom naming the project. Swipe the banner to fly to the next building, tap a storey to go into that floor, and answer questions, approve or deny once, start jobs through Reception, or stop a job.

The Mac stays the source of truth. The phone never talks to `claude`; it reads snapshots the Mac publishes and sends the Mac narrow, signed commands.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| `CitySnapshot`, `FloorMirror` | `Packages/OfficeCore/Sources/OfficeCore/Companion/` | The Mac's picture of every building and floor. `FloorMirror` runs beside each floor's reducer and keeps what `OfficeState` doesn't: captions, last tools and service calls. |
| `FloorSnapshot.events(since:)` | same | Turns two snapshots back into the `OfficeEvent`s `OfficeScene` already plays, so the phone's robots move like the Mac's. |
| `CompanionCommand`, `CommandGate` | same | Answer, allow once, deny, new job, cancel. Dictation clips travel beside them, unsigned. Each is HMAC-signed with the link key; the gate checks the signature, age (15 minutes) and replays. |
| `PairingCode`, `LinkFramer` | same | The QR code's contents, and the length-framed JSON used on the local network. |
| `LinkListener`, `LinkBrowser`, `CloudLink` | `Shared/Link/` | Bonjour and TLS-PSK on the local network; the iCloud private database for away from home. |
| `CompanionHost` | `App/CompanionHost.swift` | The Mac side: publishes snapshots, runs commands. Settings › iPhone turns it on. |
| The app | `Companion/` | `CityLink` (connection), `PhoneCity` (scene), `CityScreen` and the sheets. |

The phone builds its scenes from the same files as the Mac: `BuildingScene`, `OfficeScene`, `Worker`, `Theme` and the rest listed under the `TheCityCompanion` target in `project.yml`. `BuildingScene` takes a `TowerPlan` and any `Storey`, which the Mac's `RunController` and the phone's `PhoneStorey` both are. On iOS, `App/Platform.swift` maps the handful of AppKit colour calls onto UIKit.

## Dictation from the phone

The mic button beside the New Job field and the "Something else" answer field records on the phone and sends the audio to the Mac, whose Whisper model (Settings › Dictation) turns it into text. The phone holds no model and needs no download.

- The clip is 16 kHz mono 16-bit audio in a `LinkMessage.dictation`, up to 120 seconds (`DictationClip`). The Mac answers with `.transcript`. Only a connection that holds the link key can send it, so unlike a command it isn't separately signed.
- Local network only. Over iCloud the button is disabled, because a clip is far larger than a CloudKit record is meant to carry.
- The Mac needs a dictation model chosen. If it doesn't have one, or is busy with its own dictation, the phone shows why.
- While recording the phone switches its audio session from ambient to play-and-record, and back afterwards.

## Running it on your phone without a developer account

A free Apple ID can install apps on your own phone for 7 days at a time. Local network works; iCloud doesn't (see below).

1. In Xcode, sign in with your Apple ID (Settings › Accounts) and note your personal team ID.
2. `THECITY_TEAM=<team id> make project`, then open `TheCity.xcodeproj`, pick the `TheCityCompanion` scheme and your phone, and run.
3. On the Mac, open Settings › iPhone, turn it on, and scan the code with the phone.

Once the phone has been set up for wireless use, `THECITY_TEAM=<team id> make phone` does step 2 and the install without opening Xcode, over Wi-Fi. Set it up once: plug the phone in, turn on Developer Mode, and in Xcode's Window › Devices and Simulators tick "Connect via network". Re-run it every 7 days to renew the install. If the team can't register the bundle id, set `THECITY_BUNDLE_ID` to something unique.

`make companion` builds for the simulator, which needs no signing.

## Turning on iCloud (needs the Apple Developer Program)

CloudKit needs an iCloud entitlement, which needs a paid team and a provisioning profile. The Mac app is currently signed without a team, so `CloudLink` is compiled only with the `COMPANION_CLOUD` flag.

1. Create the container `iCloud.nz.hamish.TheCity` in the developer portal.
2. Give both targets the iCloud (CloudKit, that container) and Push Notifications capabilities, and set `COMPANION_CLOUD` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
3. Sign the Mac app with Developer ID and notarise it in the release workflow, because an app with an iCloud entitlement and no matching profile won't launch.
4. Run once in development and deploy the CloudKit schema (record types `Snapshot`, `Command`, `Receipt`, `Alert`) to production.

With that, the Mac writes the snapshot every few seconds while things change, and at least once a minute otherwise. It polls for commands every 3 seconds and writes an `Alert` record for each new question, which the phone's subscription turns into a notification.

## Security

- The link key in the QR code is the only shared secret. It signs every command and, through a derived key, is the TLS pre-shared key on the local network. Anyone who photographs the code can pair, so Settings says to show it only to your own phone. Pair Again makes a new key and unpairs every phone.
- Commands can't widen what a floor may do: there's no "always allow" and no change of permission mode from the phone.
- A command older than 15 minutes is refused, so a job queued while the Mac slept doesn't start hours later.
- Snapshots carry prompts, captions and question text, clipped, but never transcripts or tool input beyond an approval's summary.

## Not verified yet

This was written without Xcode, so none of the Swift outside OfficeCore has been compiled. OfficeCore's companion code is covered by `CompanionTests` and runs on Linux. Expect a round of compile fixes on first build, especially in `Shared/Link/LocalLink.swift` (the TLS-PSK calls) and the SwiftUI in `Companion/`.

## Sizes and timings

Decided with the first version; change them in one place.

| What | Value | Where |
|---|---|---|
| Pairing QR code | 180 pt | `CompanionSettings.codeSize` |
| Banner and panel corners | 24 pt, 20 pt | `PhoneLayout` in `Companion/CityScreen.swift` |
| Building, floor and app titles | 22, 20, 34 pt | `PhoneLayout` |
| Local network snapshot coalescing | 300 ms | `CompanionHost.localDelay` |
| iCloud publish and poll interval | 3 s | `CompanionHost.cloudInterval`, `CityLink.cloudInterval` |
| Heartbeat when nothing changes | 60 s | `CompanionHost.heartbeat` |
| Phone calls the Mac stale after | 3 min | `CityLink.stale` |
| Local command counts as unanswered after | 20 s | `CityLink.send` |
| Command lifetime | 15 min | `CommandGate.lifetime` |

The phone plays the office's sounds under the ambient audio session, so the silent switch mutes them. Its icon is the Mac icon's artwork on a full square, which iOS rounds itself.
