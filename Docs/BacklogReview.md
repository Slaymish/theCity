# Backlog review — 30 September 2026

This records the current working-tree changes against the open GitHub backlog. Issues have not been closed; implementation and verification notes are separate from release status.

## Implemented in this change

| Issue | Change | Verification |
| --- | --- | --- |
| #70 | Preserve building rise progress across scene rebuilds. | macOS build; visual transition still needs a timed window-reopen check. |
| #69 | Pause world updates while the window is closed or its scene disappears. | macOS build; idle energy profiling remains useful. |
| #64 | Expand companion setup, permissions, trust and troubleshooting documentation. | Reviewed against the device install helper. |
| #54 | Replace the unavailable macOS `timeout` command with a Perl alarm. | Used for offscreen scene renders. |
| #53 | Isolated `-data` development runs no longer start the companion link unless explicitly requested. | macOS build. |
| #42 | Explain the initial dictation model compile/prewarm wait. | macOS build; no granular model-loading API added. |
| #32 | Keep city building names visible without hover. | Dawn and twilight scene renders. |

## Partial or apparently covered

| Issue | Current evidence / remaining work |
| --- | --- |
| #7 | Building noticeboards expose recent deliveries with Run Again and Continue. File/Dock integration remains. |
| #37 | Pills resist mid-word wrapping. Minimum-width layout needs further inspection. |
| #12 | Office elapsed-time accessibility labels already exist. Hiring and broader keyboard navigation still need an audit. |
| #10 | DispatchRail already exposes cross-floor attention. Confirm the original reporting scenario before closing. |
| #29 | Welcome uses an opaque readable surface. Confirm on the current first-launch flow. |
| #61 | `make phone` and the device installation helper already exist. Verify on a connected, trusted phone. |
| #60 | Companion simulator build passes. A physical-device build is still required. |
| #62 | The guide explains free-account seven-day reinstalling and the helper. Automatic renewals are not implemented. |
| #2 | Closed-window updates are now paused. Visible-city idle CPU still needs profiling. |

## Known blockers and untouched work

#44 and #51 remain open: updating live RealityKit post-processing still crashes on macOS 27. Keep grading in offscreen renders; native daylight, sky and lamp changes work in live scenes.

#1 and #63 need the appropriate Apple developer signing/capability setup. No account or entitlement changes were made.

#71 (additional agent harnesses) remains a separate integration project.

The remaining open design, ambience, accessibility and workflow issues have not been declared resolved. Review each against the new City Hall, noticeboard and daylight controls before implementing overlapping UI.
