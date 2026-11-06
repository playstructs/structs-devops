# .references

Read-only clones of the Structs repositories (github.com/playstructs), so
people and agents can read the source behind what is deployed: compose files,
migrations, entrypoints, CLI flags, upgrade handlers.

```bash
devops refs sync            # clone or fetch every "core" repo in repos.tsv
devops refs sync --all      # core + extra
devops refs sync structsd   # just one
devops refs status          # checked-out ref, local vs remote head, and what sites pin
```

Rules:

- Only `repos.tsv`, this README and `.gitignore` are tracked. Clones are gitignored.
- Never deploy from here and never commit inside a clone. Sites deploy from their own checkouts (`site.yaml` `sources`).
- `refs sync` fetches and fast-forwards the default branch; it does not touch local changes. If a clone has local edits, it is skipped with a warning.
- To read what a site actually runs, check out the pinned commit in a worktree:
  `git -C .references/structs-webapp worktree add ../../local/worktrees/webapp-6cb5ae17 6cb5ae17`.

Where to look for common questions:

| Question | Where |
|---|---|
| Why did app.toml change after a recreate? | `docker-structsd/` entrypoint and `network-config.sh` |
| What does a migration do? | `structs-pg/deploy/`, `revert/`, `verify/` (sqitch) |
| What env does the guild stack expect? | `docker-structs-guild/compose.yaml`, `.env` template |
| How does the TSA claim and save transactions? | `structs-tsa/` and `structs-pg` signer functions |
| What does an upgrade handler migrate? | `structsd/app/upgrades/` |
| How do agents onboard a player? | `structs-ai/.cursor/skills/structs-onboarding/` |
| Chain id, peers, genesis | `structs-networks/` |
