# tools/

Everything `bin/devops` dispatches to. `tools/host/` is what runs on hosts.

- **Hub scripts** (everything outside `tools/host/`) run on macOS bash 3.2: no associative arrays, `mapfile`, `${var,,}`, `declare -n`, or `case` inside `$(...)`; expand empty arrays as `${a[@]+"${a[@]}"}`. Source `lib/*.sh`; read the inventory with `inv_*` helpers (values go to yq via `strenv`, never spliced into expressions).
- **Host scripts** (`tools/host/`) target bash 5 on Linux and never parse YAML. Synced scripts source `_bundle.sh` (site.env, `backup_file`, `install_file`); streamed scripts (no shebang) are prefixed with `_prelude.sh` by `host_bundle`.
- Every state-changing command calls `gate <tier> "<title>" "<exact command>"` before acting (`lib/gate.sh`), writes a backup before editing a file, and appends to the audit log. Tiers 0-2 run; tier 3 is only for on-chain transactions, which stop with an Approval Block. Do not use tier 3 for anything else.
- Secret values never reach the hub: load them on the host (`envget`, `volcat`), hand them to a container via `-e`, print only results. Never `--output json` on `keys add`; never capture tx stderr.
- Support `--dry-run` (`DEVOPS_DRY_RUN`) on anything that changes state: print what would run.
- `shellcheck -x` clean. Add new commands to the usage text in `bin/devops`.
