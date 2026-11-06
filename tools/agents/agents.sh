#!/usr/bin/env bash
# devops agents sync [--check] [--harness auto|none|all|cursor,claude,codex]
#     nested CLAUDE.md shims, the .claude/skills symlink (Claude Code only),
#     and the generated current-state block. --check changes nothing; exit 1 if stale.
# devops agents lint                 skills frontmatter, sizes, links, router, AGENTS.md budget
# devops agents bundle [--site S] [--skill K]...   one pasteable context file in dist/
# devops agents doctor               detected harnesses and active adapters
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"

sub="${1:-doctor}"; [ $# -gt 0 ] && shift
A="$DEVOPS_ROOT/tools/agents"
HFILE="$DEVOPS_STATE/agents.harness"

agents_files() {
  local roots=("$DEVOPS_ROOT")
  [ -d "$DEVOPS_INVENTORY" ] && roots+=("$DEVOPS_INVENTORY")
  find "${roots[@]}" \( -name .references -o -name state -o -name local -o -name dist -o -name node_modules -o -name .git \
    -o -path "$DEVOPS_ROOT/templates" -o -path "$DEVOPS_ROOT/examples" \) -prune \
    -o -name AGENTS.md -type f -print | LC_ALL=C sort -u
}

detect() {
  local out=""
  { have cursor || have cursor-agent || [ -d /Applications/Cursor.app ]; } && out="$out,cursor"
  have claude && out="$out,claude"
  have codex && out="$out,codex"
  printf '%s' "${out#,}"
}

selected() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

case "$sub" in
  sync)
    check="" harness=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --check) check=1; shift ;;
        --harness) harness="${2:-}"; shift 2 ;;
        --harness=*) harness="${1#--harness=}"; shift ;;
        *) usage_die "usage: devops agents sync [--check] [--harness auto|none|all|cursor,claude,codex]" ;;
      esac
    done
    if [ -z "$harness" ]; then harness="$(cat "$HFILE" 2>/dev/null || echo auto)"; fi
    case "$harness" in
      auto) hs="$(detect)" ;;
      all) hs="cursor,claude,codex" ;;
      none) hs="" ;;
      *) hs="$harness" ;;
    esac
    stale=0
    while IFS= read -r f; do
      d="$(dirname "$f")"; shim="$d/CLAUDE.md"
      if [ "$(cat "$shim" 2>/dev/null)" != "@AGENTS.md" ]; then
        if [ -n "$check" ]; then warn "stale shim: ${shim#"$DEVOPS_ROOT"/}"; stale=1
        else printf '@AGENTS.md\n' > "$shim"; ok "wrote ${shim#"$DEVOPS_ROOT"/}"; fi
      fi
    done < <(agents_files)
    link="$DEVOPS_ROOT/.claude/skills"
    if selected "$hs" claude; then
      if [ "$(readlink "$link" 2>/dev/null)" != "../.agents/skills" ]; then
        if [ -n "$check" ]; then warn ".claude/skills symlink missing (Claude Code selected)"; stale=1
        elif [ -e "$link" ] && [ ! -L "$link" ]; then warn ".claude/skills exists and is not a symlink; left alone"
        else mkdir -p "$DEVOPS_ROOT/.claude"; ln -sfn ../.agents/skills "$link"; ok ".claude/skills -> ../.agents/skills"; fi
      fi
    elif [ -L "$link" ] && [ -z "$check" ]; then
      rm -f "$link"; note "removed .claude/skills (Claude Code not selected)"
    fi
    if [ -n "$check" ]; then
      python3 "$DEVOPS_ROOT/tools/inventory/render.py" --check >/dev/null 2>&1 || { warn "generated blocks stale (devops inventory render)"; stale=1; }
      [ "$stale" -eq 0 ] && ok "agents sync: up to date (harness: ${hs:-none})"
      exit "$stale"
    fi
    mkdir -p "$DEVOPS_STATE"; printf '%s\n' "$harness" > "$HFILE"
    python3 "$DEVOPS_ROOT/tools/inventory/render.py" >/dev/null && ok "current-state block rendered"
    ok "agents sync done (harness: ${hs:-none})"
    selected "$hs" codex && note "codex: see docs/agents/codex.md (approvals on-request; optional rules file)"
    exit 0 ;;

  lint)
    exec python3 "$A/lint.py" ;;

  bundle)
    site="" skills=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --site) site="${2:?}"; shift 2 ;;
        --skill) skills+=("${2:?}"); shift 2 ;;
        *) usage_die "usage: devops agents bundle [--site S] [--skill K]..." ;;
      esac
    done
    if [ -n "$site" ] && [ ! -f "$DEVOPS_INVENTORY/sites/$site/site.yaml" ]; then die "unknown site $site"; fi
    mkdir -p "$DEVOPS_ROOT/dist"
    out="$DEVOPS_ROOT/dist/context-${site:-all}-$(stamp).md"
    {
      printf '# structs-devops context pack (%s%s)\n\n' "$(iso_now)" "${site:+, site $site}"
      printf 'Paste this into a chat. Propose `devops` commands one at a time; the human runs them and pastes the output. Commands that exit 10 print an Approval Block for the human.\n\n'
      printf '%s\n\n' '---' ; cat "$DEVOPS_ROOT/AGENTS.md"
      if [ -f "$DEVOPS_INVENTORY/AGENTS.md" ]; then printf '\n%s\n\n' '---'; cat "$DEVOPS_INVENTORY/AGENTS.md"; fi
      printf '\n%s\n\n## Skills available\n\n' '---'
      python3 "$A/lint.py" --index | while IFS="$(printf '\t')" read -r n dsc; do printf -- '- **%s**: %s\n' "$n" "$dsc"; done
      if [ -n "$site" ]; then
        printf '\n%s\n\n## Site %s\n\n' '---' "$site"
        cat "$DEVOPS_INVENTORY/sites/$site/README.md" 2>/dev/null || echo "(no README)"
      fi
      for k in ${skills[@]+"${skills[@]}"}; do
        f="$DEVOPS_ROOT/.agents/skills/$k/SKILL.md"
        [ -f "$f" ] || die "unknown skill $k (devops agents lint lists them)"
        printf '\n%s\n\n## Skill %s\n\n' '---' "$k"; cat "$f"
      done
      rep="$(find "$DEVOPS_REPORTS/runs" -type f -name '*.md' ${site:+-name "*$site*"} 2>/dev/null | while read -r x; do printf '%s\t%s\n' "$(stat -f %m "$x" 2>/dev/null || stat -c %Y "$x")" "$x"; done | sort -rn | head -1 | cut -f2)"
      if [ -n "$rep" ]; then printf '\n%s\n\n## Latest run report (%s)\n\n' '---' "${rep#"$DEVOPS_ROOT"/}"; cat "$rep"; fi
      jf="$(find "$DEVOPS_REPORTS/journal" -maxdepth 1 -name '20*.md' 2>/dev/null | sort | tail -1)"
      if [ -n "$jf" ]; then
        printf '\n%s\n\n## Latest journal entry (%s)\n\n' '---' "$(basename "$jf")"
        awk '/^## /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$jf"
      fi
    } > "$out"
    if ! python3 "$DEVOPS_ROOT/tools/secrets/scan.py" "$out" >&2; then
      rm -f "$out"; die "the bundle matched a secret pattern and was not written; fix the source file first"
    fi
    ok "$out ($(wc -c < "$out" | tr -d ' ') bytes)" ;;

  doctor)
    rc=0
    det="$(detect)"
    sel="$(cat "$HFILE" 2>/dev/null || echo "auto (not synced yet)")"
    ok "harnesses on this machine: ${det:-none}; selected: $sel"
    if [ -x "$A/guard.sh" ] && have python3; then ok "guard: tools/agents/guard.sh"; else err "guard.sh missing or python3 missing"; rc=1; fi
    if [ -f "$DEVOPS_ROOT/.cursor/hooks.json" ] && grep -q 'guard.sh cursor' "$DEVOPS_ROOT/.cursor/hooks.json"; then
      ok "cursor: AGENTS.md + .agents/skills; beforeShellExecution guard (open structs-devops/ as the project)"
    else warn "cursor: .cursor/hooks.json does not call the guard"; fi
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DEVOPS_ROOT/.claude/settings.json" 2>/dev/null; then
      if [ "$(readlink "$DEVOPS_ROOT/.claude/skills" 2>/dev/null)" = "../.agents/skills" ]; then
        ok "claude: CLAUDE.md, settings.json (deny + PreToolUse guard), .claude/skills linked"
      else
        note "claude: settings.json ok; .claude/skills not linked (devops agents sync --harness claude)"
      fi
    else warn "claude: .claude/settings.json missing or invalid"; fi
    if [ -f "$HOME/.codex/rules/structs-devops.rules" ]; then cx="rules installed"; else cx="no rules file (optional, docs/agents/codex.md)"; fi
    ok "codex: AGENTS.md + .agents/skills; protection is the devops tier gate; $cx"
    if selected "$det" cursor && [ -L "$DEVOPS_ROOT/.claude/skills" ]; then
      note "cursor and claude adapters both active: Cursor may list each skill twice (.agents/skills and .claude/skills)"
    fi
    python3 "$A/lint.py" | tail -1
    python3 "$A/lint.py" >/dev/null || { err "agents lint has errors (devops agents lint)"; rc=1; }
    exit "$rc" ;;

  *) usage_die "usage: devops agents sync [--check] [--harness H] | lint | bundle [--site S] [--skill K] | doctor" ;;
esac
