# Contributing

Bug reports, ideas and pull requests are all welcome.

## Issues

Everything still to do is tracked in [GitHub Issues](https://github.com/Slaymish/theCity/issues). Before opening one, search to see whether it's already there. If it is, a 👍 or a comment with your case helps decide what comes next.

[Open an issue](https://github.com/Slaymish/theCity/issues/new/choose) and pick **Bug report** or **Idea or improvement**. A short, rough issue is better than none. Security problems go through [SECURITY.md](SECURITY.md) instead.

### Labels

| Group | Labels | Meaning |
|---|---|---|
| Type | `bug`, `enhancement`, `performance`, `accessibility`, `documentation`, `question` | What kind of issue it is |
| Area | `area: city`, `area: office`, `area: reception`, `area: core`, `area: settings`, `area: assets`, `area: release` | Which part of the app it touches |
| Priority | `priority: high`, `priority: medium`, `priority: low` | How soon it's likely to be worked on |
| Status | `needs triage`, `needs repro`, `blocked` | Where it's up to |
| Contributors | `good first issue`, `help wanted` | Open for anyone to pick up |
| Closed as | `duplicate`, `wontfix`, `invalid` | Why it was closed without a change |

New issues start as `needs triage`. Triage adds an area and a priority and removes that label.

## Pull requests

1. Comment on the issue you're picking up so nobody else starts it too.
2. Follow [Building from source](README.md#building-from-source), and run `make test` and `make build` before opening the PR.
3. Keep the PR to one change and link the issue with `Fixes #123`.
