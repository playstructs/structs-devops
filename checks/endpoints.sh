#!/usr/bin/env bash
# endpoints <site>: every declared HTTP/TCP endpoint answers as expected.
# Fields per endpoint: id, url | tcp, expect (status), method, origin,
# expect_header, content_type, json (jq expression that must be true),
# lag_json (jq path to a block lag, judged with sync thresholds), resolve, optional.
. "$DEVOPS_ROOT/checks/_lib.sh"
check_site_arg "${1:-}"; site="$1"
need curl jq

slow="${DEVOPS_HTTP_SLOW_SECONDS:-3}"
eps="$(yq -o=json -I=0 '.endpoints // []' "$(inv_site_file "$site")")"
n="$(printf '%s' "$eps" | jq 'length')"
[ "$n" -gt 0 ] || check_ok "no endpoints declared"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/devops-ep.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT

i=0
while [ "$i" -lt "$n" ]; do
  e="$(printf '%s' "$eps" | jq -c ".[$i]")"; i=$((i + 1))
  g() { printf '%s' "$e" | jq -r ".$1 // empty"; }
  id="$(g id)"; opt="$(g optional)"
  fail_lvl=2; [ "$opt" = "true" ] && fail_lvl=1
  tcp="$(g tcp)"
  if [ -n "$tcp" ]; then
    if have nc; then tcp_ok() { nc -z -w 5 "${tcp%:*}" "${tcp##*:}" >/dev/null 2>&1; }
    else tcp_ok() { perl -e 'alarm 5; exec @ARGV' bash -c "exec 3<>/dev/tcp/${tcp%:*}/${tcp##*:}" 2>/dev/null; }; fi
    if tcp_ok; then detail "ok: $id tcp $tcp open"
    else bump "$fail_lvl" "$id: tcp $tcp not reachable"; fi
    continue
  fi
  url="$(g url)"; want="$(g expect)"; want="${want:-200}"
  args=(-sS -o "$tmp/body" -D "$tmp/hdr" -m 15 -w '%{http_code} %{time_total}')
  [ -n "$(g resolve)" ] && args+=(--resolve "$(g resolve)")
  [ -n "$(g method)" ] && args+=(-X "$(g method)")
  [ -n "$(g origin)" ] && args+=(-H "Origin: $(g origin)" -H 'Access-Control-Request-Method: GET')
  out="$(curl "${args[@]}" "$url" 2>"$tmp/err")" || {
    bump "$fail_lvl" "$id: $(head -c 160 "$tmp/err" | tr '\n' ' ')"; continue; }
  code="${out% *}"; t="${out#* }"
  if [ "$code" != "$want" ]; then bump "$fail_lvl" "$id: HTTP $code (expected $want) $url"; continue; fi
  msg="$id $code in ${t}s"
  ct="$(g content_type)"
  if [ -n "$ct" ] && ! grep -qi "^content-type: *$ct" "$tmp/hdr"; then
    bump 1 "$id: content-type is '$(grep -i '^content-type:' "$tmp/hdr" | head -1 | cut -d: -f2- | tr -d '\r ')' (expected $ct)"; continue
  fi
  hh="$(g expect_header)"
  if [ -n "$hh" ] && ! grep -qi "^$hh:" "$tmp/hdr"; then bump "$fail_lvl" "$id: response lacks header $hh"; continue; fi
  jx="$(g json)"
  if [ -n "$jx" ] && [ "$(jq -r "$jx" "$tmp/body" 2>/dev/null)" != "true" ]; then
    bump "$fail_lvl" "$id: JSON assertion failed: $jx"; continue
  fi
  lj="$(g lag_json)"
  if [ -n "$lj" ]; then
    lag="$(jq -r "$lj // empty" "$tmp/body" 2>/dev/null)"
    if [ -n "$lag" ]; then
      bump "$(level_high "$lag" "$(thr "$site" sync.lag_blocks_warn 20)" "$(thr "$site" sync.lag_blocks_crit 200)")" "$id lag $lag blocks"
    fi
  fi
  if python3 -c "import sys; sys.exit(0 if float('$t') > $slow else 1)"; then bump 1 "$msg (slow, > ${slow}s)"
  else detail "ok: $msg"; fi
done
check_finish "$n endpoints answering"
