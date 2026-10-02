# Codex in The City

Choose **Codex** under Settings › General › New jobs start with › Agent. A new floor uses your Codex account and configured default model. You can select a model from the installed CLI's model inventory when hiring. Existing floors keep Claude until you change their Agent menu while they are idle.

Install the [Codex CLI](https://developers.openai.com/codex/quickstart) and run `codex login`, or use the floor's **Sign In…** button. The app finds the executable on its rebuilt PATH or in the Codex/ChatGPT application bundles. Choose a binary under Settings › General › Codex if needed.

Codex runs through the [app-server protocol](https://developers.openai.com/codex/app-server). Each floor saves its thread ID and working directory so **Continue** resumes the conversation. New-worktree jobs use the same Git worktree helper as other checkout operations. Cancelling interrupts the process, with termination as a fallback.

## Permissions

| The City mode | Codex policy |
| --- | --- |
| Auto | Workspace-write sandbox; asks for additional access (`on-request`). |
| Accept edits | Workspace-write sandbox; asks for untrusted commands (`untrusted`). |
| Ask every time | Workspace-write sandbox; asks for untrusted commands (`untrusted`). Trusted reads and workspace edits can proceed. |
| Plan only | Read-only sandbox with approvals disabled (`never`). |

Command and file approvals appear on the existing desk cards. Codex's structured questions use the same answer cards. Permission mode changes apply between jobs; an active Codex turn keeps the policy it started with. Unsupported server requests receive an explicit error so the agent can report the limitation.

## Differences from Claude floors

- Codex uses its own account, skills, MCP services and agent configuration. Claude account selection and per-job skill/service blocking apply to Claude floors.
- Hired departments give Codex stage guidance; Claude-specific agent definitions and tool allowlists are not installed as Codex roles.
- Codex has no dollar budget cap in this integration. The app hides the budget control and Claude account usage gauge on Codex floors. Token totals are shown when supplied by Codex; a dollar cost is not inferred.
- The embedded terminal takeover currently supports Claude floors. Codex work runs through the office's job and follow-up controls.
- Switching a floor's provider clears its active conversation association and model selection. Saved job history stays available.
- Reception's optional Claude Haiku routing and naming helpers remain separate from the floor's selected agent. Use Apple Intelligence under Settings › Reception to route locally.

For a development launch, `-provider codex` selects Codex for new floors and `-codex-cli /path/to/codex` overrides its executable.
