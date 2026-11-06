# Host probe (streamed). Env: N_STACKS, STACK_<i>_ID, STACK_<i>_CMD (compose prefix). Read-only.
# Prints one line per container: c=<stack>|<service>|<state>|<health>|<exitcode>|<restarts>|<name>
i=0
while [ "$i" -lt "${N_STACKS:-0}" ]; do
  idv="STACK_${i}_ID"; cmdv="STACK_${i}_CMD"
  sid="${!idv}"; cmd="${!cmdv}"
  json="$(eval "$cmd ps -a --format json" 2>/dev/null || true)"
  if [ -z "$json" ]; then echo "stack_err=$sid"; i=$((i + 1)); continue; fi
  # "|" rather than tabs: IFS whitespace would collapse an empty Health field.
  printf '%s\n' "$json" | jq -r 'if type=="array" then .[] else . end | [.Service, .State, (.Health // ""), (.ExitCode // 0), .Name] | map(tostring) | join("|")' |
  while IFS='|' read -r svc state health code name; do
    rc="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)"
    echo "c=$sid|$svc|$state|$health|$code|$rc|$name"
  done
  i=$((i + 1))
done
