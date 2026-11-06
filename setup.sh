#!/usr/bin/env bash
# Set up the structs-devops workspace on this hub machine. Safe to re-run.
#
#   ./setup.sh [--refs core|all|none] [--harness auto|none|all|cursor,claude,codex]
#              [--no-link] [--no-ssh] [--non-interactive]
#
# 1. checks hub tools          5. clones .references (core by default)
# 2. creates .devops.env       6. creates your inventory if missing (devops init),
# 3. creates state/ and local/    validates it and renders state blocks
# 4. links bin/devops          7. installs the pre-commit secret scan (git repos only)
#                              8. writes harness adapters, then runs devops doctor
set -uo pipefail

DEVOPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEVOPS_ROOT
# shellcheck source=lib/common.sh
. "$DEVOPS_ROOT/lib/common.sh"

refs=core harness=auto link=1 ssh=1
while [ $# -gt 0 ]; do
  case "$1" in
    --refs) refs="${2:-}"; shift 2 ;;
    --refs=*) refs="${1#--refs=}"; shift ;;
    --harness) harness="${2:-}"; shift 2 ;;
    --harness=*) harness="${1#--harness=}"; shift ;;
    --no-link) link=""; shift ;;
    --no-ssh) ssh=""; shift ;;
    --non-interactive) DEVOPS_NONINTERACTIVE=1; export DEVOPS_NONINTERACTIVE; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_die "unknown option $1 (see ./setup.sh --help)" ;;
  esac
done
case "$refs" in core|all|none) ;; *) usage_die "--refs must be core, all or none" ;; esac

failed=0
step() { printf '\n== %s\n' "$*" >&2; }

# 1. Hub tools ---------------------------------------------------------------
step "hub tools"
hint() {
  if [ "$(uname -s)" = Darwin ]; then echo "brew install $1"; else echo "apt-get install -y $2"; fi
}
missing=""
for t in git curl jq ssh openssl python3 perl shasum; do
  if have "$t"; then ok "$t"; else err "$t missing"; missing="$missing $t"; fi
done
if have yq && yq_is_mikefarah; then ok "yq $(yq --version 2>&1 | grep -Eo 'v?4\.[0-9.]+' | head -1)"
else err "yq (mikefarah v4) missing or wrong flavour: $(hint yq yq) (or https://github.com/mikefarah/yq/releases)"; missing="$missing yq"; fi
for t in shellcheck nc; do
  have "$t" && ok "$t (optional)" || note "optional: $t ($(hint "$t" "$( [ "$t" = nc ] && echo netcat-openbsd || echo "$t")"))"
done
if [ -n "$missing" ]; then
  err "install the missing tools and re-run:$missing"
  [ "$(uname -s)" = Darwin ] && info "  e.g. brew install jq yq"
  exit 1
fi

# 2. .devops.env -------------------------------------------------------------
step ".devops.env"
if [ -f "$DEVOPS_ROOT/.devops.env" ]; then ok "exists (left as is)"
else cp "$DEVOPS_ROOT/.devops.env.example" "$DEVOPS_ROOT/.devops.env"; ok "created from .devops.env.example (edit DEVOPS_NOTIFY)"; fi

# 3. state/ and local/ ------------------------------------------------------
step "state/ and local/"
mkdir -p "$DEVOPS_STATE"/{checks,jobs,alerts,approvals,logs} "$DEVOPS_LOCAL"
chmod 700 "$DEVOPS_LOCAL" "$DEVOPS_STATE/approvals"
if [ ! -f "$DEVOPS_LOCAL/secrets.env" ]; then
  umask 077
  cat > "$DEVOPS_LOCAL/secrets.env" <<'EOF'
# Hub-only values referenced as local-env:<NAME> (notification channels, API
# tokens for the hub). Mode 600, git-ignored. Never put host secrets here.
# NTFY_TOPIC=
# DISCORD_WEBHOOK_URL=
# MATRIX_NOTIFY_TOKEN=
# MATRIX_NOTIFY_ROOM=
# WEBHOOK_URL=
# GITHUB_TOKEN=
EOF
  ok "created local/secrets.env (600)"
else
  ok "local/secrets.env exists"
fi
find "$DEVOPS_ROOT/bin" "$DEVOPS_ROOT/tools" "$DEVOPS_ROOT/checks" "$DEVOPS_ROOT/crons" -type f \
  \( -name '*.sh' -o -name '*.py' -o -name devops \) ! -path '*/host/_*' -exec chmod +x {} +

# 4. devops on PATH ----------------------------------------------------------
step "devops command"
if [ -n "$link" ]; then
  mkdir -p "$HOME/.local/bin"
  dst="$HOME/.local/bin/devops"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$DEVOPS_ROOT/bin/devops" ]; then ok "$dst already links here"
  elif [ -e "$dst" ] || [ -L "$dst" ]; then warn "$dst exists and points elsewhere ($(readlink "$dst" 2>/dev/null || echo file)); left alone. Use $DEVOPS_ROOT/bin/devops"
  else ln -s "$DEVOPS_ROOT/bin/devops" "$dst"; ok "linked $dst"; fi
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) note "add ~/.local/bin to PATH (or run ./bin/devops)";; esac
else
  note "skipped (--no-link); use ./bin/devops"
fi

# 5. .references -------------------------------------------------------------
step ".references ($refs)"
case "$refs" in
  none) note "skipped; later: devops refs sync" ;;
  core) "$DEVOPS_ROOT/bin/devops" refs sync || { warn "some repos failed to clone (re-run devops refs sync)"; failed=1; } ;;
  all)  "$DEVOPS_ROOT/bin/devops" refs sync --all || { warn "some repos failed to clone (re-run devops refs sync --all)"; failed=1; } ;;
esac

# 6. inventory ---------------------------------------------------------------
step "inventory (${DEVOPS_INVENTORY#"$DEVOPS_ROOT"/})"
if [ ! -f "$DEVOPS_INVENTORY/network.yaml" ]; then
  "$DEVOPS_ROOT/bin/devops" init || { warn "devops init failed"; failed=1; }
fi
if [ -f "$DEVOPS_INVENTORY/network.yaml" ]; then
  mkdir -p "$DEVOPS_REPORTS"/{runs,journal,incidents}
  if "$DEVOPS_ROOT/bin/devops" inventory validate; then
    "$DEVOPS_ROOT/bin/devops" inventory render >/dev/null && ok "rendered the inventory AGENTS.md and site READMEs"
  else
    warn "inventory has errors; fix them before using site commands"; failed=1
  fi
fi

# 7. secret scan hook --------------------------------------------------------
step "pre-commit secret scan"
"$DEVOPS_ROOT/bin/devops" secrets hook install || note "after git init in the framework or inventory, run: devops secrets hook install"

# 8. harness adapters + doctor ----------------------------------------------
step "agent harness adapters ($harness)"
if [ "$harness" != none ]; then
  "$DEVOPS_ROOT/bin/devops" agents sync --harness "$harness" || { warn "agents sync failed"; failed=1; }
else
  note "skipped; later: devops agents sync"
fi

step "doctor"
dargs=()
[ -z "$ssh" ] && dargs=(--no-ssh)
"$DEVOPS_ROOT/bin/devops" doctor ${dargs[@]+"${dargs[@]}"} || failed=1

echo >&2
if [ "$failed" -eq 0 ]; then
  ok "setup complete. Next: devops site new <id> ... (or devops health all if you have sites; crons: devops cron install)"
else
  warn "setup finished with warnings above"
fi
exit "$failed"
