# Changelog

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
