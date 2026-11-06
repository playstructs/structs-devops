# Using the workspace with an LLM

The instructions are written once, harness-neutral, and loaded natively by
each tool. Safety does not depend on the harness: `bin/devops` enforces the
tiers and Approval Blocks itself. The hooks below are a second layer.

| | Cursor | Claude Code | Codex | No harness (chat) |
|---|---|---|---|---|
| Always-loaded instructions | `AGENTS.md` (+ nested) | `CLAUDE.md` → `@AGENTS.md` (+ nested shims) | `AGENTS.md` root → cwd (32 KiB cap) | paste `devops agents bundle` output |
| Skills | `.agents/skills/` | `.claude/skills` → symlink to `.agents/skills` | `.agents/skills/` | include with `--skill` |
| Workflow skills | `/structs-start` | `/structs-start` | `$structs-start` | ask for the steps |
| Command guard | `.cursor/hooks.json` (`beforeShellExecution`) | `.claude/settings.json` (`PreToolUse` + deny rules) | approvals `on-request`; optional rules ([codex.md](codex.md)) | the human runs commands |
| Tier gate | `bin/devops` | `bin/devops` | `bin/devops` | `bin/devops` |

Open `structs-devops/` itself as the project (not a parent folder) so the
root `AGENTS.md`, skills and hooks are picked up.

## Setup

```bash
./setup.sh --harness auto          # detects cursor/cursor-agent, claude, codex on PATH
devops agents sync --harness claude,cursor
devops agents doctor               # which adapters are active, what protects each harness
devops agents lint                 # skill frontmatter, sizes, links, AGENTS.md budget
```

`agents sync` writes the nested `CLAUDE.md` shims, the `.claude/skills`
symlink (only when Claude Code is selected, so Cursor does not load every
skill twice through its `.claude/skills` compatibility path), and refreshes
the generated current-state block.

## What the guard does

`tools/agents/guard.sh` classifies every shell command with
`tools/agents/policy.tsv` (`tools/agents/classify.py`):

- **deny**: anything that would print secret material: reading `.env`,
  `userlist.txt`, `priv_validator_key.json`, `node_key.json`, keyrings,
  `printenv`, `docker inspect … .Config.Env`, `keys add --output json`.
- **ask**: re-running a devops command with `--approve` (so the human confirms
  the Approval Block in the harness UI too), tier 3 commands, and tier 2
  commands that touch hosts or services (raw `ssh … docker compose restart`,
  `systemctl`, `psql` writes).
- everything else: the harness's normal permission flow.

Try it: `tools/agents/guard.sh check -- 'ssh root@guild.example.org cat /root/docker-structs-guild/.env'`.

## No harness

`devops agents bundle --site <guild> --skill structs-debug-http` writes one
markdown file to `dist/` with `AGENTS.md`, the current state, the site
README, the chosen skills, the latest run report and the newest journal
entry. It is scanned for secrets before it is written. Paste it into any
chat; the model proposes `devops` commands, you run them and paste output
back (the "No shell" section of `AGENTS.md`).
