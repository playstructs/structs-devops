# Codex

Codex reads `AGENTS.md` from the repository root down to the working
directory (combined cap 32 KiB; `devops agents lint` keeps us under it) and
skills from `.agents/skills/`. Workflow skills are invoked as `$structs-start`,
`$structs-daily-check`, and so on.

Codex has no shell-command hook equivalent to the Cursor and Claude Code
guards, so the **tier gate in `bin/devops` is the main protection**: tier 2
and 3 actions stop with exit 10 and an Approval Block whatever runs them.

## Recommended settings

Run Codex with approvals on request and the workspace-write sandbox, so any
command that reaches the network or leaves the workspace asks first:

```toml
# ~/.codex/config.toml (or a profile you use for this workspace)
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = false
```

ssh to hosts and chain queries need network access: approve those commands
one at a time when Codex asks, rather than turning network access on for the
whole session.

## Optional command rules

If your Codex version supports execution-policy rules (`~/.codex/rules/`),
copy [codex.rules](codex.rules) there. It forbids the secret-printing patterns
and prompts for raw service changes, mirroring `tools/agents/policy.tsv`.
Check it loads with your Codex version's rules check command before relying
on it.

## Session habits

- Start with `$structs-start`; end with `$structs-handoff`.
- When a devops command exits 10, Codex must show you the Approval Block and
  wait. Re-running with `--approve <token>` is your decision.
