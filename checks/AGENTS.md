# checks/

Read-only health checks. Catalog: `catalog.tsv`. Runner: `run.sh <group> <target>`.
One check: `devops check <id> [site]`. Human docs: `docs/health-checks.md`.

## Contract (every check must follow it)

- First stdout line: `<OK|WARN|CRIT|UNKNOWN> <check-id> <scope>: <summary>`; detail lines after it are indented.
- Exit 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN. A probe that fails (ssh down, psql error) is UNKNOWN or CRIT, never a crash: checks use `set -uo pipefail`, not `set -e` (see `_lib.sh`).
- Read-only. A check never restarts, applies, pushes the host bundle, runs certbot, votes or broadcasts. If a check needs a synced host tool and the bundle is stale, it WARNs and tells the operator to run `devops host sync` (`_bundle.sh`).
- Thresholds come from `thr SITE path default`: site `checks.<path>` overrides the inventory's `network.yaml check_defaults.<path>`, which overrides the preset's (`networks/<preset>.yaml`).
- State between runs (heights, restart counts, disk history) goes in `cstate_get/cstate_set`, under `state/checks/<scope>/`.
- No secret values. Secret checks use `secret_probe_cmd` (test/stat/grep -c).

## Adding a check

1. Write `checks/<id>.sh`: source `_lib.sh` (and `_pg.sh` or `_bundle.sh` if needed), call `check_site_arg "$1"` for site checks, collect findings with `bump LEVEL "message"` and `detail "..."`, finish with `check_finish "ok summary"`.
2. Host-side data: add a probe under `checks/host/` that prints `key=value` lines (bash 5 on the host, never parses YAML; container names arrive via `site_preamble`). Read it with `probe SITE HOST "$PREAMBLE" SCRIPT` and `pv key`.
3. Add a row to `catalog.tsv` (id, scope, group, applies, description).
4. Add default thresholds to `check_defaults` in each `networks/*.yaml` preset (and as the `thr` fallback) if any, and document them in `docs/health-checks.md`.
5. `shellcheck -x checks/<id>.sh`, then `devops check <id> <site>`.

## Bash versions

Hub scripts here run on macOS bash 3.2: no associative arrays, no `mapfile`, no `case` inside `$(...)`, expand empty arrays as `${a[@]+"${a[@]}"}`. Host probes may use bash 5.
