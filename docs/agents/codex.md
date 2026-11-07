# Codex

Codex reads `AGENTS.md` from the repository root down to the working
directory (combined cap 32 KiB; `devops agents lint` keeps us under it) and
skills from `.agents/skills/`. Workflow skills are invoked as `$structs-start`,
`$structs-daily-check`, and so on.

Codex has no shell-command hook equivalent to the Cursor and Claude Code
guards. Transaction approval comes from `bin/devops` (its broadcasts stop
with exit 10 and an Approval Block whatever runs them) and, optionally, the
rules file below for raw `structsd tx`.

## Settings

The agent needs network access for ssh and chain queries. A setup that lets
it work without asking for each command:

```toml
# ~/.codex/config.toml (or a profile you use for this workspace)
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
```

If ssh needs files outside the workspace (keys, known_hosts, control
sockets) and the sandbox blocks it, use a profile with
`sandbox_mode = "danger-full-access"` for this workspace.

## Optional command rules

If your Codex version supports execution-policy rules (`~/.codex/rules/`),
copy [codex.rules](codex.rules) there. It forbids the secret-printing patterns
and prompts before a raw `structsd tx`, mirroring `tools/agents/policy.tsv`.
Check it loads with your Codex version's rules check command before relying
on it.

## Session habits

- Start with `$structs-start`; end with `$structs-handoff`.
- When a devops command exits 10 it is a transaction: Codex shows you the
  Approval Block and waits. Re-running with `--approve <token>` is your decision.
