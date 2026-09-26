# Fixtures

Raw `claude -p --output-format stream-json --verbose` output captured from `SampleWorkspace/` with Claude Code 2.1.283, 26 September 2026.

| File | How it was made |
|---|---|
| `three-rooms.jsonl` | Real run: research, then build, then review, one after another. Manager on Sonnet, rooms on Haiku |
| `not-logged-in.jsonl` | Real run with `CLAUDE_CONFIG_DIR` pointed at an empty directory |
| `cancelled.jsonl` | Real run sent SIGINT as soon as the first `task_started` arrived |
| `haiku-manager.jsonl` | Real run with Haiku as manager: it ran every room as a **background** subagent (`async_launched`), one turn per room, four `result` lines flushed at exit |
| `ask-question.jsonl` | Real run with `--input-format stream-json --permission-prompt-tool stdio` after an `initialize` control request. Shows the `can_use_tool` request for `AskUserQuestion`; the host's reply (`{"behavior":"allow","updatedInput":{…,"answers":{"Which colour do you prefer?":"Blue"}}}`) went to stdin so isn't in the file |
| `ask-question-print-mode.jsonl` | Same request with plain `-p` and `--permission-prompts none`: `AskUserQuestion` is not in the tool list at all |
| `ask-question-host-probe.jsonl` | `--permission-prompts host` plus `initialize`: handshake works, still no `AskUserQuestion` |
| `always-allow.jsonl` | Real run: the host answered a Bash approval with `updatedPermissions` set to the request's `permission_suggestions`; the CLI then wrote `Bash(curl -sI https://example.com)` to `.claude/settings.local.json` itself |
| `follow-up-resume.jsonl` | Real run started with `--resume <session_id>` of a finished session: same `session_id`, and the model remembered the earlier turn |
| `budget-exceeded.jsonl` | Real run with `--max-budget-usd 0.01`: `result` has `subtype: error_max_budget_usd`, `terminal_reason: budget_exhausted` and an `errors` array; exit code 1 |
| `skill-and-mcp.jsonl` | Real run: the manager loads the `office-house-style` project skill (`Skill` tool), loads and calls `mcp__specification-website__search` (via `ToolSearch`, then an approval), and a subagent does the same MCP call (approval carries its `agent_id`) |
| `inventory.jsonl` | Real run with an invalid `--model`: the CLI still sends the `initialize` response (commands with descriptions) and `system/init` (skills, MCP servers), then fails with `model_not_found` at a reported cost of 0. The app uses this to list skills before a job |
| `mcp-list.txt` | Real `claude mcp list` output (URLs replaced): health-checked status for each server |
| `malformed.jsonl` | Hand-made: `three-rooms.jsonl` with non-JSON, truncated, non-object, untyped, blank and unknown-subtype lines spliced in |

Account emails in `initialize` responses are replaced with `redacted@example.com`. The `*.stderr.txt` files are each real run's stderr (all empty).
