---
name: structs-dev-merge-upstream
description: Resolves merge conflicts when a long-lived deployment branch (typically a guild's own structs-webapp branch, i.e. main plus local changes) takes the latest origin/main. Keeps both main's change and the branch's own feature, never drops branch commits, and leaves the result for review. Use when a pipeline merge stage reports conflicts, when merging origin/main into a custom guild branch stops with conflicts, or when the merged branch no longer builds.
---

# Merging main into a deployment branch

A deployment branch is `main` plus changes some guilds deploy before (or
instead of) upstream merging them. Which branch, and which sites run it, is in
the operator's inventory: the pipeline file's merge stage and the sites'
`sources`. It takes `origin/main` with a normal merge ("Merge
remote-tracking branch 'origin/main' into <branch>"), never a rebase, because
guild hosts pull it with `--ff-only`.

## When to use

- A merge stage is `needs_fix` with a conflict list in the task prompt.
- The merge is clean but the stage's build (`npm --prefix src run build` for
  structs-webapp) fails.

## Procedure

1. See what the branch carries that main does not:
   `git log --oneline --no-merges origin/main..HEAD` and
   `git diff origin/main...HEAD --stat` (HEAD is the branch before the
   merge; during a conflicted merge use `git log ORIG_HEAD`).
2. For each conflicted file, compare the two sides:
   `git diff :1:<file> :2:<file>` (branch) and `git diff :1:<file> :3:<file>`
   (main). Understand both intents before editing.
3. Resolve so both changes survive. If main now does natively what the
   branch added, prefer main's version and say so in the summary (the
   branch commit can then be dropped upstream).
4. Remove every conflict marker, then `git add <file>` for each resolved
   file. Do not commit; the pipeline commits the merge after review.
5. If the merge was clean but the build fails, fix the smallest thing that
   makes the build pass; the pipeline commits it as a separate commit on top
   of the merge.

## Rules

- Never rebase, reset, force or drop commits from the branch.
- Never resolve by taking one side wholesale (`git checkout --ours/--theirs`)
  unless the other side's change is provably already contained.
- Lockfiles (`package-lock.json`, `composer.lock`): take main's, then the
  build re-resolves; mention it.
- `.env` and secrets are never in conflicts you should resolve by guessing;
  stop and say so.

## Verification

`git diff --name-only --diff-filter=U` is empty, no `<<<<<<<` / `>>>>>>>`
markers remain, and the build passes. The reviewer reads
`devops pipeline show <run> <stage> --diff` (a remerge diff of exactly how
each conflict was resolved).
