# <Runbook title>

**Applies to:** <site kinds or site ids>  **Tier:** <highest tier of any step>
**Last exercised:** <YYYY-MM-DD on site>

## When to use

The trigger: a symptom, a release, or a planned change.

## Before you start

- Read-only checks that must pass first (`devops health <site>`, ...).
- Backups to take and where they go.
- Who to tell (public-node changes are announced first).

## Steps

1. Step with the exact `devops` command (or `ssh` command if no tool exists yet).
2. ...

## Verify

`devops check <id> <site>` lines that must read OK.

## Rollback

Exact commands to undo, and the point after which rollback is not possible.

## Known failure modes

| Symptom | Cause | Fix |
|---|---|---|
