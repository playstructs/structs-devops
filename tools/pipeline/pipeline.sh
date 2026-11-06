#!/usr/bin/env bash
# devops pipeline list | validate                       [0] $DEVOPS_PIPELINES/*.yaml (inventory/pipelines/)
# devops pipeline status [pipeline] [--deployed]         [0] what is behind the trigger (fetches into local/)
# devops pipeline run <pipeline> [--stage S] [--continue] [--force] [--fresh] [--no-agent] [--sha SHA]
#                                                        [1] hub-local clones only: update, check, fix, commit, verify
# devops pipeline show [run] [stage] [--diff|--check|--prompt|--agent|--log|--verify]   [0]
# devops pipeline publish <run> <stage> [--site S]       [2] push the prepared commit; [3] with a release tag;
#                                                            deploy stages run `devops deploy` (its own approval)
# devops pipeline watch                                  [0] trigger refs that moved (cron: pipeline-watch)
# devops pipeline discard <run> [stage...]               [0] prepared commits will not be published
#
# Format and safety model: docs/pipelines.md.
set -euo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need git yq jq python3

ENGINE="$DEVOPS_ROOT/tools/pipeline/engine.py"
engine() { python3 -B "$ENGINE" "$@"; }
sub="${1:-list}"; [ $# -gt 0 ] && shift

case "$sub" in
  list|validate|status|run|show|watch|discard|check-anchors) engine "$sub" "$@" ;;
  publish)
    [ $# -ge 2 ] || usage_die "usage: devops pipeline publish <run> <stage> [--site S]"
    run_id="$1" stage="$2"; shift 2
    site=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --site) site="${2:?--site needs a site}"; shift 2 ;;
        *) usage_die "unknown argument $1" ;;
      esac
    done
    plan="$(engine publish-plan "$run_id" "$stage" ${site:+--site "$site"})" || exit 1
    kind="$(printf '%s' "$plan" | jq -r .kind)"
    case "$kind" in
      git)
        tier="$(printf '%s' "$plan" | jq -r .tier)"
        title="$(printf '%s' "$plan" | jq -r .title)"
        action="$(printf '%s' "$plan" | jq -r .action)"
        GATE_EFFECT="$(printf '%s' "$plan" | jq -r .effect)"
        GATE_ROLLBACK="$(printf '%s' "$plan" | jq -r .rollback)"
        GATE_VERIFY="$(printf '%s' "$plan" | jq -r .verify)"
        GATE_EXTRA="$(printf '%s' "$plan" | jq -r .extra)
Review first: devops pipeline show $run_id $stage --diff"
        if [ -n "${DEVOPS_DRY_RUN:-}" ]; then
          printf '%s\n%s\n' "$title" "$action"; note "dry run: nothing pushed"; exit 0
        fi
        gate "$tier" "$title" "$action"
        audit "PIPELINE publish run=$run_id stage=$stage"
        engine publish-exec "$run_id" "$stage"
        ;;
      deploy)
        site="$(printf '%s' "$plan" | jq -r .site)"
        proc="$(printf '%s' "$plan" | jq -r .procedure)"
        target="$(printf '%s' "$plan" | jq -r .target)"
        info "deploy $site ($proc) to ${target:0:8} through devops deploy; it asks for its own approval"
        rc=0
        DEVOPS_RERUN="pipeline publish $run_id $stage --site $site" "$DEVOPS_ROOT/bin/devops" deploy "$site" "$proc" || rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        [ -n "${DEVOPS_DRY_RUN:-}" ] && exit 0
        engine deploy-record "$run_id" "$stage" "$site"
        ;;
      *) die "unexpected publish plan: $plan" ;;
    esac
    ;;
  -h|--help|help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) usage_die "unknown: devops pipeline $sub (devops pipeline help)" ;;
esac
