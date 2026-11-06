# inventory/

This operator's inventory: what runs where, and its history. It is its own
repo, kept private if you like, and read by the structs-devops framework (format:
`docs/inventory.md` there). Read the current-state block below at the start of
every session.

| Path | What |
|---|---|
| `network.yaml` | additions to the public preset named by `preset:` (voters, public-node site, image pins, peers) |
| `sites/<id>/` | `site.yaml` (source of truth), README, CHANGELOG, patches, site runbooks (`devops site new`) |
| `shared/patches/` | overlays and snippets used by more than one site (`@shared/...` in manifests) |
| `tools/host/` | your own host helpers, bundled with the framework's (`patches.pre_helpers`) |
| `pipelines/` | dev pipelines (`devops pipeline`; format `docs/pipelines.md` in the framework) |
| `reports/` | incidents, journal, reviews (tracked); runs, tx-log, audit.log (ignored) |
| `publish-markers.txt` | extra names `devops publish-check` keeps out of the public framework |

## Rules

- Never write a secret value anywhere here. Secrets are pointers under `secrets:` (`host-env:`, `host-file:`, `host-volume:`, `local-env:`). The validator rejects values that look like mnemonics, PEM keys or passwords.
- Only record what you confirmed on the host or the chain. Put inferred values in `unverified:` until someone checks them; bump `last_verified` when you confirm the file.
- After every change on a host, update `site.yaml` (versions, digests, commits, ids) and add a dated line to the site `CHANGELOG.md`.
- Edit `site.yaml`, never the generated blocks between `<!-- BEGIN GENERATED -->` markers; run `devops inventory render` afterwards.
- Run `devops inventory validate` before you finish.
- Host ids are unique across all sites. Do not rename ids that other files reference (`gov.voters`, `dependents`, secret refs).
- Anything that would help every operator (a check, a skill, a generic runbook fix) belongs in the framework, written without your site names; `devops publish-check` there enforces that.

## Current state

<!-- BEGIN GENERATED: current-state -->
<!-- END GENERATED: current-state -->
