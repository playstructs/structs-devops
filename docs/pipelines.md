# Dev pipelines

A pipeline carries one upstream change through the repos that consume it.
Pipelines are inventory files (`inventory/pipelines/<id>.yaml`), so each
operator follows only its own repos. Two shapes cover most needs:

- **Submodule stages**: a repo that vendors another moves its submodule to the
  new commit and proves it still works (structs-desktop following
  structs-webapp, with its sed-anchor check; a translation overlay such as
  structs-kor, with its translation audit).
- **Merge and deploy**: a long-lived branch (a guild's own webapp branch) gets
  upstream `main` merged in, then a deploy stage rolls it out to every site
  whose inventory says it runs that branch.
  `examples/inventory/pipelines/webapp-guild-branch.yaml` is this shape.

Everything up to a local commit and a passing build happens on the hub, in
clones under `local/pipelines/repos/` whose push URL is disabled. Nothing
leaves the hub until `devops pipeline publish`. Operator skill:
[structs-dev-pipeline](../.agents/skills/structs-dev-pipeline/SKILL.md).

## Commands

```
devops pipeline list                          pipelines and their triggers
devops pipeline validate [files]              schema, repos, skills, gate rules
devops pipeline status [id] [--deployed]      what is behind (read-only; --deployed reads guild checkouts over ssh)
devops pipeline run <id> [--dry-run]          prepare every stage that is not done
    --stage S        only S (repeatable); re-prepares it even if ready
    --sha SHA        use this trigger commit (must be on the trigger ref unless --force)
    --continue       after fixing by hand in the clone: keep the worktree, re-check, commit, verify
    --fresh          new run id instead of resuming the run for this sha
    --no-agent       never start an agent CLI; failed checks write prompt.md
    --force          prepare even when the stage already has the commit
devops pipeline show [run] [stage] [--diff|--check|--prompt|--agent|--log|--verify]
devops pipeline publish <run> <stage> [--site S]
devops pipeline watch                         what cron runs: compare triggers with the last look
devops pipeline discard <run> [stage...]      prepared commits will not be published (the next run re-prepares)
```

`run` resumes the run for the same trigger commit
(`state/pipelines/runs/<id>-<sha8>/`); published, ready and up-to-date stages
are skipped unless named with `--stage`. Each run writes a report to
`inventory/reports/runs/<date>/pipeline-<run>.md`.

## Stage lifecycle

```
repo stage:  update -> setup -> check -> (fix by agent, up to N times) -> commit -> verify -> ready
                                   \-> needs_fix (prompt.md) -> you or any agent fix -> --continue
             ready -> publish -> published
deploy stage: needs earlier stages done -> compare each tracking site with the branch head
             -> publish --site S (devops deploy) -> deployed
```

| Status | Meaning |
|---|---|
| `up_to_date` | Branch already has the trigger commit (or the site runs the head) |
| `ready` | Local commit made, checks and build passed, waiting for publish |
| `needs_fix` | Checks failed; `prompt.md` describes what to fix |
| `failed` | A command or guard failed; `show --log` |
| `waiting` | A deploy stage waits for `needs` |
| `published` / `deployed` | Pushed (and tagged) / rolled out |
| `discarded` | You threw the prepared commit away; the next `run` prepares again |

## File format

```yaml
schema: structs-devops/pipeline/v1
id: webapp-desktop              # equals the file name
description: ...
trigger:
  repo: structs-webapp          # name in .references/repos.tsv, or set url:
  ref: main                     # branch to watch
  on_change: notify             # notify (default) or prepare (cron prepares stages; never publishes)
stages:
  - id: desktop                 # lowercase-hyphenated, unique
    repo: structs-desktop       # or url: for a repo not in repos.tsv (forks, test repos)
    branch: main                # branch the stage commits to and pushes
    update:                     # exactly one:
      submodule: structs-webapp #   move this submodule to the trigger commit
      # merge: origin/main      #   merge the trigger commit into branch
    setup: [npm ci]             # commands before checks (cwd = clone)
    check:                      # each entry is one of:
      - npm test                #   a command (pass = exit 0)
      - run: npm run lint       #   the same, explicit
      - merge-clean             #   no unmerged paths, no conflict markers in changed files
      - sed-anchors:            #   replay a sed patch script and report which edits did nothing
          script: scripts/apply-patches.sh
          copy: {structs-webapp/src/js: js}   # build the tree the script expects (in a temp dir)
          require: script       #   all: every in-place sed must change something; script: trust the script's own exit
          expect_files: [js/index.js]         # files the script must touch (catches skipped loops)
    fix:                        # optional; without it a failed check is needs_fix right away
      skill: structs-dev-anchors              # .agents/skills/<skill>/SKILL.md, given to the agent
      attempts: 2               # 0..5
      args: {language: Korean}  # extra lines for the prompt
    verify: [npm run build]     # after the commit; the worktree is reset afterwards
    commit: "Follow {upstream} {short} ({summary})"
    publish:
      push: true
      tag: next-patch           # optional: highest vX.Y.Z on the remote + 1, annotated
      triggers: "what GitHub builds from this push"
  - id: guild-custom
    repo: structs-webapp
    branch: guild-custom
    update: {merge: origin/main}
    check: [merge-clean]
    fix: {skill: structs-dev-merge-upstream, attempts: 1}
    verify: [npm --prefix src ci, npm --prefix src run build]
    publish: {push: true}
  - id: deploy
    needs: [guild-custom]
    deploy:
      repo: structs-webapp
      ref: guild-custom         # sites whose inventory sources say repo + ref
      procedure: webapp-update  # devops deploy <site> <procedure>
```

Commit placeholders: `{upstream}` `{ref}` `{short}` `{sha}` `{prs}`
(`#144, #145`) `{summary}` (`PR #145`, else the newest subject) `{count}`
`{branch}`. Unknown placeholders stay as written.

Deploy targets come from `inventory/sites/*/site.yaml` `sources`, so a guild
that deploys `main` (or another branch) is simply not picked by a pipeline
that deploys `guild-custom`. Give it its own pipeline or deploy stage.

## Safety model

- Hub-local clones only (`local/pipelines/repos/<repo>`, blobless). The push
  URL is `no-push://use-devops-pipeline-publish`; your own working copies are
  never touched.
- Checks, agents and builds never push. `publish` pushes to the explicit URL
  with `GIT_TERMINAL_PROMPT=0` after re-checking that the remote branch has
  not moved since prepare, that the commit is the one reviewed and that the
  tag is still free.
- Publishing is tier 2 and runs without an approval token. A release tag
  reaches players and cannot be recalled, so check the build before
  publishing a tagged stage. Older pipeline files may still carry `gate:` or
  `publish.tier`; both are ignored.
- A trigger commit that moves a submodule backwards (an old `--sha`) is
  marked `REWIND` in the summary and in the publish title.
- Merge stages remember conflict resolutions (`git rerere` in the hub clone),
  so re-preparing after the branch moved does not need the same fix twice.
  A reused resolution is a warning in the summary and the publish output;
  review it with `show --diff` (remerge diff). Forget them with
  `rm -rf local/pipelines/repos/<repo>/.git/rr-cache`.
- Agent guards: the agent works in the clone with the skill and the check
  output. If it commits, the commits are folded back into the worktree; if
  HEAD moves off the prepared base, the push URL changes or (for overlay
  repos) the upstream submodule is edited, the stage fails.
- Deploys go through `devops deploy`, which prints its plan and writes a run
  report.

## Agent runners

Fix steps use the first installed of `cursor-agent`, `claude`, `codex`.
Without one, the stage is `needs_fix` with `prompt.md`: paste it into any
agent opened in the printed clone path, or fix by hand, then `--continue`.

| Variable | Effect |
|---|---|
| `DEVOPS_AGENT_CLI` | `auto` (default), `none`, or `cursor-agent` / `claude` / `codex` |
| `DEVOPS_AGENT_CMD` | Custom runner, e.g. `my-agent --cwd {workdir} --prompt-file {prompt_file}` |
| `DEVOPS_AGENT_TIMEOUT` | Seconds per attempt (default 1800) |
| `DEVOPS_PIPELINE_VERIFY_TIMEOUT` | Seconds per verify command (default 3600) |
| `DEVOPS_PIPELINES` | Read pipeline files from another directory (default `inventory/pipelines`) |
| `DEVOPS_DRY_RUN=1` | `run` prints the plan; `publish` prints what it would push |

## Files

| Path | What |
|---|---|
| `inventory/pipelines/<id>.yaml` | Definitions (tracked in your inventory repo) |
| `local/pipelines/repos/` | Hub clones (gitignored) |
| `state/pipelines/runs/<run>/run.json` | Run state; per stage: `log.txt`, `check.md`, `prompt.md`, `agent-N.log`, `agent-N.diff`, `diff.patch`, `verify.log` |
| `state/pipelines/<id>.last_seen` | Last trigger commit seen by `watch` |
| `inventory/reports/runs/<date>/pipeline-<run>.md` | Human report per run |
| `crons/jobs/pipeline-watch.sh` | Hourly watch (in `crons/schedules.yaml`; installed only by `devops cron install`) |

## Adding a pipeline

1. Add missing repos to `.references/repos.tsv` (or use `url:`).
2. Copy `examples/inventory/pipelines/webapp-guild-branch.yaml` (or the
   format above) into `inventory/pipelines/`, keep the stages you need, write a fix skill per
   check that an agent can repair (`.agents/skills/<name>/SKILL.md`).
3. `devops pipeline validate`, `devops pipeline run <id> --dry-run`, then a
   real `run` (nothing leaves the hub) and review with `show --diff`.

Fits: any repo that vendors another as a submodule (structs-desktop
following structs-ai, a new translation overlay), any long-lived branch that
follows upstream (a guild's own deploy branch), and deploying that branch to
the sites whose inventory tracks it.

Does not fit (v1): changes that are not a submodule bump or a merge (image
digest bumps, compose or env edits: use `devops deploy` procedures and
patches), opening pull requests instead of pushing, tags other than the next
`vX.Y.Z` patch, and repo stages that wait for each other (`needs` is honored
by deploy stages only).
