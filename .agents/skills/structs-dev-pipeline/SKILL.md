---
name: structs-dev-pipeline
description: Runs and publishes dev pipelines (inventory/pipelines/*.yaml) that carry an upstream change, such as a merge to structs-webapp main, through the repos that consume it - submodule bumps with checks (structs-desktop anchors and release tag, translation overlays such as structs-kor), merges into a guild's own deployment branch - and on to guild deploys. Covers status, preparing stages in hub-local clones, agent fix steps, reviewing diffs, publishing, resuming after a manual fix, and adding a new pipeline. Use when structs-webapp (or another trigger repo) changed and downstream repos need updating, when the user asks to propagate, sync, bump, tag or release after an upstream merge, or when a pipeline stage is failing or ready to publish.
---

# Dev pipelines

A pipeline is a list of stages triggered by one upstream ref. Pipelines live
in the operator's inventory (`devops pipeline list` shows them). Each repo
stage works in a hub-local clone (`local/pipelines/repos/<repo>`, push URL
disabled): update (submodule bump or merge), setup, checks, an agent fix only
when a check fails, a local commit, then verify (the real build). Nothing
leaves the hub until `devops pipeline publish` pushes it. Deploy stages run
`devops deploy`. The pipeline is a convenience: merging, bumping or pushing
by hand in your own clone is fine too.
Format: [docs/pipelines.md](../../../docs/pipelines.md).

## When to use

- "webapp main merged, update the downstream repos / our branch / deploy".
- `pipeline-watch` reported that a trigger moved.
- A stage is `needs_fix`, `failed` or `ready` in `devops pipeline status`.
- Someone wants a new propagation (another overlay, a fork, a guild branch).

## Decisions

| Situation | Command |
|---|---|
| Which pipelines exist | `devops pipeline list` |
| What is behind | `devops pipeline status <pipeline>` (`--deployed` reads each guild checkout over ssh) |
| Prepare everything | `devops pipeline run <pipeline>` |
| One stage again | `devops pipeline run <pipeline> --stage <stage>` |
| After fixing by hand in the clone | `devops pipeline run <pipeline> --stage <stage> --continue` |
| Review before publishing | `devops pipeline show <run> <stage> --diff` (also `--check`, `--agent`, `--prompt`, `--log`, `--verify`) |
| Push one stage | `devops pipeline publish <run> <stage>` |
| Deploy after the branch is pushed | `devops pipeline run <pipeline> --stage deploy`, then `devops pipeline publish <run> deploy --site <site>` per site |
| The user rejects a prepared change, or it was a test | `devops pipeline discard <run> [stage]` |

## Procedure

1. `devops pipeline status <pipeline>`. Stages that already contain the
   trigger commit say `current`; prepare only matters for the others.
2. `devops pipeline run <pipeline>`. Read the summary: `ready` (commit made,
   build passed), `up_to_date`, `needs_fix`, `failed`, `waiting`.
3. `needs_fix`: the checks failed and no agent CLI was available, or it ran
   out of attempts. The stage wrote `prompt.md` (what failed, upstream
   commits, the fix skill). Fix in the clone path it prints, by hand or by
   giving that prompt to any agent working in that directory, then
   `--continue`. Leave the fix uncommitted; `--continue` commits it.
4. For each `ready` stage, read `show <run> <stage> --diff` and the check
   result, then `publish`. Tell the user what went out.
5. Order: submodule stages are independent of each other. A stage with
   `tag:` pushes the branch and then a release tag; for structs-desktop the
   release builds and ships to players and cannot be recalled, so be sure the
   build passed. A merged branch is published before its deploy stage.
6. Deploy: `run --stage deploy` compares each tracking site's checkout with
   the branch head; publish it one site at a time
   (`publish <run> deploy --site <site>`). The deploy procedure prints its
   plan and report.
7. Finish: `devops pipeline status <pipeline> --deployed`; record deploys in
   each site's `CHANGELOG.md`.

## Failure signatures

| Signature | Meaning | Next |
|---|---|---|
| `moved since prepare` at publish | Someone pushed to that branch | `run --stage <id>` again (rebuilds on the new head) |
| `the next tag is now vX` | A tag appeared after the stage was prepared | Re-run publish |
| `the agent changed the upstream submodule` | Agent edited `structs-webapp/` inside an overlay repo | Re-run the stage; overlays never edit upstream |
| desktop `NOT RUN ... BannerViewModel.js` | Upstream moved or renamed a banner view model; the patch loop skipped it | Fix `scripts/apply-patches.sh` paths (`structs-dev-anchors`) |
| translation audit `stale` / `untranslated` | Upstream English changed or was added | `structs-dev-translations` |
| merge stage conflicts | main and the branch changed the same lines | `structs-dev-merge-upstream`; always review the remerge diff |
| `reused the resolution from an earlier run` | git rerere replayed a resolution after a re-prepare | Check the remerge diff before publishing |
| `REWIND` in the publish title | The trigger commit is older than the current pin | Almost always a mistake: `discard` the run |
| `npm ci`: `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` | Node on the hub cannot find a CA bundle (Homebrew openssl without `cert.pem`) | Fix the hub's Node/OpenSSL, or run with `NODE_OPTIONS=--use-bundled-ca` |
| `git user.email is not set` | The hub commits as the user | `git config --global user.email ...` |
| push fails with auth | No git credentials for github.com on the hub | Configure a credential helper or SSH remote; the pipeline never prompts |

## Adding a pipeline

Copy `examples/inventory/pipelines/webapp-guild-branch.yaml` (or start from
the format in `docs/pipelines.md`) into `inventory/pipelines/`, change the
trigger and stages, add any new repo to `.references/repos.tsv` (or set
`url:` for a fork), then `devops pipeline validate` and
`devops pipeline run <id> --dry-run`. Deploy stages pick sites from
`inventory/sites/*/site.yaml` `sources` (`repo` + `ref`), so a guild that
tracks a different branch only needs its inventory entry.

## Verification

- `devops pipeline status <id>` shows every repo stage `current` and any tag
  stage `includes it`.
- `--deployed` shows each tracking site on the branch head.
- GitHub Actions for the pushed repos (Pages, Release), in the browser or
  with `gh run list` if installed.
