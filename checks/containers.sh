#!/usr/bin/env bash
# containers <site>: compose services running/healthy, one-shots exited 0, restart increases.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
f="$(inv_site_file "$site")"

hosts=""
for st in $(inv_stack_ids "$site"); do
  h="$(stack_host "$site" "$st")"
  case " $hosts " in *" $h "*) ;; *) hosts="$hosts $h" ;; esac
done

total=0
for h in $hosts; do
  pre=""; i=0
  for st in $(inv_stack_ids "$site"); do
    [ "$(stack_host "$site" "$st")" = "$h" ] || continue
    pre="${pre}STACK_${i}_ID=$(printf '%q' "$st")
STACK_${i}_CMD=$(printf '%q' "$(inv_compose_cmd "$site" "$st")")
"
    i=$((i + 1))
  done
  pre="${pre}N_STACKS=$i"
  if ! probe "$site" "$h" "$pre" "$DEVOPS_ROOT/checks/host/containers.sh"; then
    bump 3 "$h: probe failed (ssh unreachable?)"; continue
  fi
  for e in $(printf '%s\n' "$PROBE" | sed -n 's/^stack_err=//p'); do bump 1 "$h stack $e: docker compose ps failed"; done

  seen=" "
  while IFS='|' read -r _ svc state health code rc name; do
    [ -n "$svc" ] || continue
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    total=$((total + 1))
    # Stacks can share a compose project, so look the service up across all of them.
    declared="$(SV="$svc" yq -r '[.stacks[].services | select(has(strenv(SV)))] | length > 0' "$f")"
    one_shot="$(SV="$svc" yq -r '[.stacks[].services | select(has(strenv(SV))) | .[strenv(SV)].one_shot // false][0] // false' "$f")"
    case "$svc" in *-init) one_shot=true ;; esac
    ignored=false; inv_ignored_service "$site" "$svc" && ignored=true

    key="restarts.$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
    prev="$(cstate_get "$key")"; cstate_set "$key" "$rc"
    if [ -n "$prev" ] && [ "$rc" -gt "$prev" ] 2>/dev/null; then
      bump 1 "$svc restarted $((rc - prev))x since the last check (RestartCount $rc)"
    fi

    case "$state" in
      running)
        case "$health" in
          unhealthy) if $ignored; then detail "$svc unhealthy (ignored per checks.ignore_unhealthy)"; else bump 2 "$svc is unhealthy"; fi ;;
          starting)  bump 1 "$svc health check still starting" ;;
          *)         detail "ok: $svc running${health:+ ($health)}" ;;
        esac ;;
      exited)
        if [ "$one_shot" = "true" ] && [ "$code" = "0" ]; then detail "ok: $svc one-shot exited 0"
        elif [ "$declared" = "true" ]; then bump 2 "$svc exited (code $code)"
        else bump 1 "$svc exited (code $code), not declared in inventory"; fi ;;
      restarting) bump 2 "$svc is restart-looping" ;;
      created)    bump 1 "$svc created but never started" ;;
      paused)     bump 1 "$svc is paused" ;;
      *)          bump 2 "$svc state $state" ;;
    esac
  done <<EOF
$(printf '%s\n' "$PROBE" | sed -n 's/^c=//p')
EOF

  for st in $(inv_stack_ids "$site"); do
    [ "$(stack_host "$site" "$st")" = "$h" ] || continue
    for svc in $(S="$st" yq -r '.stacks[] | select(.id == strenv(S)) | .services | keys | .[]' "$f"); do
      printf '%s\n' "$PROBE" | grep -q "^c=[^|]*|$svc|" ||
        bump 1 "$st/$svc declared in inventory but no container exists"
    done
  done
done
check_finish "$total containers healthy"
