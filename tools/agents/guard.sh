#!/usr/bin/env bash
# Harness shell-command guard. Agents may use any command; this only makes sure
# the user approves on-chain transactions and that secret values stay put.
#
#   guard.sh claude          Claude Code PreToolUse hook (Bash): JSON on stdin
#   guard.sh cursor          Cursor beforeShellExecution hook: JSON on stdin
#   guard.sh check -- <cmd>  print the decision for a command (for testing)
#
# Decisions, from tools/agents/policy.tsv via classify.py:
#   deny  commands that would print secret material (class S)
#   ask   an on-chain transaction (tier 3), and re-running devops with
#         --approve (the user must have approved that transaction)
#   none  everything else (the harness's normal permission flow applies)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-check}"; [ $# -gt 0 ] && shift

if [ "$mode" = check ]; then
  [ "${1:-}" = "--" ] && shift
  cmd="$*"
else
  cmd="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print(ti.get("command") or d.get("command") or "", end="")
' 2>/dev/null)"
fi

decision="none" reason=""
if [ -n "$cmd" ]; then
  cls="$(python3 "$HERE/classify.py" -- "$cmd" 2>/dev/null)"
  tier="${cls%% *}"; why="${cls#* }"
  case "$tier" in
    S) decision=deny; reason="refused: $why. Secret values stay on their host; check presence with: devops secrets audit <site>" ;;
    3) decision=ask; reason="on-chain transaction: $why. Transactions need the user's approval; devops tx simulates first and shows what will be signed." ;;
  esac
  if [ "$decision" != deny ] && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]/])(devops|bin/devops)[[:space:]].*--approve([[:space:]=]|$)'; then
    decision=ask
    reason="sends an on-chain transaction with an approval token. Run it only if the user approved this transaction in this conversation."
  fi
fi

json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

case "$mode" in
  check)
    printf '%s\t%s\n' "$decision" "${reason:-${cls:-}}"
    case "$decision" in deny) exit 2 ;; ask) exit 1 ;; *) exit 0 ;; esac ;;
  claude)
    case "$decision" in
      deny) printf '%s\n' "$reason" >&2; exit 2 ;;
      ask) printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' "$(json "$reason")" ;;
    esac
    exit 0 ;;
  cursor)
    case "$decision" in
      deny) printf '{"permission":"deny","user_message":%s,"agent_message":%s}\n' "$(json "$reason")" "$(json "$reason")" ;;
      ask)  printf '{"permission":"ask","user_message":%s,"agent_message":%s}\n' "$(json "$reason")" "$(json "$reason")" ;;
      *)    printf '{"permission":"allow"}\n' ;;
    esac
    exit 0 ;;
  *) echo "usage: guard.sh claude|cursor|check -- <cmd>" >&2; exit 2 ;;
esac
