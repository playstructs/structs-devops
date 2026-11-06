#!/usr/bin/env bash
# devops doctor [--no-ssh]     [0] is this hub ready to manage the inventory?
#   hub tools, workspace files, inventory, .references, BatchMode ssh to every
#   host, unattended-ssh readiness for crons, dev pipeline prerequisites,
#   harness adapters.
# Exit 1 when something required is missing or a host is unreachable.
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/inventory.sh"
. "$DEVOPS_ROOT/lib/ssh.sh"

do_ssh=1
for a in "$@"; do
  case "$a" in --no-ssh) do_ssh="" ;; *) usage_die "usage: devops doctor [--no-ssh]" ;; esac
done

fails=0 warns=0
bad()  { err "$*"; fails=$((fails + 1)); }
meh()  { warn "$*"; warns=$((warns + 1)); }
section() { printf '\n== %s\n' "$*" >&2; }

section "hub tools"
ver() { "$@" 2>&1 | head -1 | cut -c1-60; }
for t in git curl jq ssh openssl python3 perl shasum; do
  have "$t" || { bad "$t missing (./setup.sh)"; continue; }
  case "$t" in
    ssh) ok "ssh $(ver ssh -V)" ;;
    perl|shasum) ok "$t" ;;
    *) ok "$t $(ver "$t" --version)" ;;
  esac
done
if have yq && yq_is_mikefarah; then ok "yq $(ver yq --version)"; else bad "yq must be mikefarah/yq v4"; fi
have shellcheck && ok "shellcheck (optional)" || note "optional: shellcheck (lint before committing tool changes)"
have nc && ok "nc (optional)" || note "optional: nc (tcp endpoint checks fall back to bash /dev/tcp)"
ok "bash ${BASH_VERSION} (hub scripts target 3.2+)"

section "workspace"
[ -f "$DEVOPS_ROOT/.devops.env" ] && ok ".devops.env" || meh ".devops.env missing (cp .devops.env.example .devops.env)"
[ -f "$(inv_network_file)" ] && ok "inventory $DEVOPS_INVENTORY" || bad "no network.yaml under $DEVOPS_INVENTORY"
if [ -f "$DEVOPS_LOCAL/secrets.env" ]; then
  mode="$(stat -f '%Lp' "$DEVOPS_LOCAL/secrets.env" 2>/dev/null || stat -c '%a' "$DEVOPS_LOCAL/secrets.env")"
  case "$mode" in 600|400) ok "local/secrets.env mode $mode" ;; *) bad "local/secrets.env mode $mode (chmod 600)" ;; esac
fi
notify="${DEVOPS_NOTIFY:-stdout}"
ok "notify channels: $notify"
case "$DEVOPS_ROOT" in
  "$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Downloads"*|"$HOME/Library/Mobile Documents"*)
    [ "$(uname -s)" = Darwin ] && meh "workspace is in a macOS-protected folder: launchd crons need Full Disk Access for /bin/bash (crons/README.md)" ;;
esac
slug="$(printf '%s' "$DEVOPS_ROOT" | sha_short | cut -c1-8)"
n_cron="$(find "$HOME/Library/LaunchAgents" -name "io.structs-devops.$slug.*.plist" 2>/dev/null | wc -l | tr -d ' ')"
c_cron="$(crontab -l 2>/dev/null | grep -c "# structs-devops:$slug" || true)"
if [ "${n_cron:-0}" -gt 0 ] || [ "${c_cron:-0}" -gt 0 ]; then ok "crons installed: ${n_cron} launchd, ${c_cron} crontab (devops cron status)"
else note "no crons installed (devops cron install when ready)"; fi

section "inventory"
if out="$(python3 "$DEVOPS_ROOT/tools/inventory/validate.py" 2>&1)"; then
  ok "$(printf '%s\n' "$out" | tail -1)"
else
  bad "$(printf '%s\n' "$out" | tail -1) (devops inventory validate)"
fi
if python3 "$DEVOPS_ROOT/tools/inventory/render.py" --check >/dev/null 2>&1; then ok "generated blocks current"
else meh "generated blocks stale (devops inventory render)"; fi

section ".references"
core=0 cloned=0
while IFS="$(printf '\t')" read -r name _ _ group _; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$group" = core ] || continue
  core=$((core + 1))
  [ -d "$DEVOPS_REFS/$name/.git" ] && cloned=$((cloned + 1))
done < "$DEVOPS_REFS/repos.tsv"
if [ "$cloned" -eq "$core" ]; then ok "$cloned/$core core repos cloned"
else meh "$cloned/$core core repos cloned (devops refs sync)"; fi

section "hosts"
if [ -z "$do_ssh" ]; then
  note "skipped (--no-ssh)"
else
  for s in $(inv_sites); do
    for h in $(inv_host_ids "$s"); do
      t="$(ssh_target "$s" "$h")"
      if [ "$t" = local ]; then
        if have docker && docker info >/dev/null 2>&1; then ok "$s:$h local (docker ok)"
        else meh "$s:$h local: docker not running"; fi
        continue
      fi
      start=$(now_epoch)
      if host_ping "$s" "$h"; then
        ok "$s:$h $t ($(( $(now_epoch) - start ))s)"
        idf="$(ssh -G "$t" 2>/dev/null | awk '$1=="identityfile"{print $2}' | sed "s|^~|$HOME|")"
        found=""
        for f in $idf; do [ -f "$f" ] && found=1; done
        if [ -z "$found" ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
          meh "$s:$h works through ssh-agent only; launchd/cron jobs will not see it. Set IdentityFile (and UseKeychain yes on macOS) for $t in ~/.ssh/config"
        fi
      else
        bad "$s:$h $t: BatchMode ssh failed (key not loaded, host key unknown, or host down). Try: ssh $t true"
      fi
    done
  done
fi

section "dev pipelines"
if out="$(python3 -B "$DEVOPS_ROOT/tools/pipeline/engine.py" validate 2>&1)"; then ok "$(printf '%s\n' "$out" | tail -1)"
else bad "$(printf '%s\n' "$out" | tail -1) (devops pipeline validate)"; fi
runner=""
if [ -n "${DEVOPS_AGENT_CMD:-}" ]; then runner="custom (DEVOPS_AGENT_CMD)"
elif [ "${DEVOPS_AGENT_CLI:-auto}" != none ]; then
  for b in cursor-agent claude codex; do have "$b" && { runner="$b"; break; }; done
fi
[ -n "$runner" ] && ok "pipeline fix runner: $runner" || note "no agent CLI (cursor-agent, claude, codex): pipeline fix steps write prompt.md for you"
git config user.email >/dev/null 2>&1 && ok "git user.email set (pipelines commit as you)" || meh "git user.email not set; pipeline commits will fail"
if have node; then
  if node -e "require('https').get('https://registry.npmjs.org/',r=>process.exit(0)).on('error',e=>{console.error(e.code);process.exit(1)})" >/dev/null 2>&1; then
    ok "node $(node --version) reaches registry.npmjs.org over TLS"
  else
    meh "node $(node --version) cannot verify TLS to registry.npmjs.org: npm ci in pipelines fails (Homebrew: check the openssl cert.pem link; workaround NODE_OPTIONS=--use-bundled-ca)"
  fi
else
  note "node not installed (needed by the webapp-main pipeline's npm steps)"
fi

section "agent adapters"
if [ -x "$DEVOPS_ROOT/tools/agents/agents.sh" ]; then
  "$DEVOPS_ROOT/tools/agents/agents.sh" doctor || warns=$((warns + 1))
else
  meh "tools/agents/agents.sh missing"
fi

echo >&2
if [ "$fails" -gt 0 ]; then err "doctor: $fails problem(s), $warns warning(s)"; exit 1; fi
ok "doctor: ready ($warns warning(s))"
