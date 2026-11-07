# Using the workspace with an LLM

The instructions are written once, harness-neutral, and loaded natively by
each tool. Agents may work however suits the task: `devops` helpers, ssh,
docker, git, SQL. Two things are enforced. On-chain transactions need the
user's approval (`bin/devops` prints an Approval Block for its own broadcasts,
and the hooks below ask before raw ones), and commands that would print
secret values are refused.

| | Cursor | Claude Code | Codex | No harness (chat) |
|---|---|---|---|---|
| Always-loaded instructions | `AGENTS.md` (+ nested) | `CLAUDE.md` → `@AGENTS.md` (+ nested shims) | `AGENTS.md` root → cwd (32 KiB cap) | paste `devops agents bundle` output |
| Skills | `.agents/skills/` | `.claude/skills` → symlink to `.agents/skills` | `.agents/skills/` | include with `--skill` |
| Workflow skills | `/structs-start` | `/structs-start` | `$structs-start` | ask for the steps |
| Command guard | `.cursor/hooks.json` (`beforeShellExecution`) | `.claude/settings.json` (`PreToolUse` + deny rules) | approvals `on-request`; optional rules ([codex.md](codex.md)) | the human runs commands |
| Transaction approval | `bin/devops` + hook | `bin/devops` + hook | `bin/devops` (+ rules) | `bin/devops` |

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
- **ask**: on-chain transactions sent outside `devops` (`structsd tx …`,
  the REST `/cosmos/tx/v1beta1/txs` and RPC `broadcast_tx_*` endpoints), and
  re-running a devops command with `--approve` (so the human confirms that
  transaction in the harness UI too).
- everything else, including restarts, recreates, deploys, pushes and
  database writes: allowed (the harness's own settings still apply).

Try it: `tools/agents/guard.sh check -- 'ssh root@guild.example.org cat /root/docker-structs-guild/.env'`.

## No harness

`devops agents bundle --site <guild> --skill structs-debug-http` writes one
markdown file to `dist/` with `AGENTS.md`, the current state, the site
README, the chosen skills, the latest run report and the newest journal
entry. It is scanned for secrets before it is written. Paste it into any
chat; the model proposes `devops` commands, you run them and paste output
back (the "No shell" section of `AGENTS.md`).
