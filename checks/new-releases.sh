#!/usr/bin/env bash
# new-releases (network): upstream changes the operator should know about.
#   - structsd tags newer than the network's binary.version          -> WARN
#   - structs/structsd:<tag> digest differs from the inventory pin  -> WARN
#     (a recreate would silently change the node binary)
#   - other image digests and repo heads that moved since the last run -> detail
#   - source pins (e.g. a webapp branch) whose commit is now on main    -> detail
. "$DEVOPS_ROOT/checks/_lib.sh"
need git curl jq

REPOS="$DEVOPS_ROOT/.references/repos.tsv"
url_of() { awk -F'\t' -v n="$1" '$1 == n {print $2}' "$REPOS"; }

# 1. structsd release tags
inv_ver="$(inv_net '.binary.version')"
tags="$(git ls-remote --tags --refs "$(url_of structsd)" 'v*' 2>/dev/null | sed 's#.*refs/tags/##')"
if [ -z "$tags" ]; then
  bump 3 "could not list structsd tags (network?)"
else
  newest="$(printf '%s\n' "$tags" | python3 -c '
import re, sys
def key(t):
    m = re.match(r"v(\d+)\.(\d+)\.(\d+)(.*)", t)
    return (int(m[1]), int(m[2]), int(m[3]), m[4] == "", m[4]) if m else (0, 0, 0, False, t)
ts = [t.strip() for t in sys.stdin if t.strip()]
print(sorted(ts, key=key)[-1])')"
  if [ "$newest" != "$inv_ver" ] && [ "$(printf '%s\n%s\n' "$inv_ver" "$newest" | sort -t. -k1,1V -k2,2n -k3,3n 2>/dev/null | tail -1)" = "$newest" ]; then
    bump 1 "structsd $newest is tagged; inventory runs $inv_ver (is an upgrade proposal coming? devops gov list)"
  else
    detail "ok: newest structsd tag $newest"
  fi
fi

# 2. image digests on Docker Hub vs inventory pins
hub_digest() {
  curl -sS -m 15 "https://hub.docker.com/v2/namespaces/${1%%/*}/repositories/${1#*/}/tags/$2" 2>/dev/null | jq -r '.digest // empty' 2>/dev/null
}
for img in $(yq -r '(.images // {}) | keys | .[]' "$(inv_network_file)"); do
  repo="$(inv_net ".images.\"$img\".repo")"; tag="$(inv_net ".images.\"$img\".tag")"
  pin="$(inv_net ".images.\"$img\".digest")"
  [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$pin" ] || continue
  case "$repo" in */*) ;; *) repo="library/$repo" ;; esac
  d="$(hub_digest "$repo" "$tag")"
  [ -n "$d" ] || { detail "$img: Docker Hub digest unavailable"; continue; }
  case "$d" in
    "$pin"*) detail "ok: $repo:$tag still ${pin:0:19}" ;;
    *)
      if [ "$img" = "structsd" ]; then
        bump 1 "$repo:$tag on Docker Hub is now ${d:0:19} (inventory pins ${pin:0:19}); review before any structsd recreate"
      else
        detail "$repo:$tag on Docker Hub is now ${d:0:19} (inventory pins ${pin:0:19})"
      fi ;;
  esac
done

# 3. repo heads that moved since the last run
prev="$(cstate_get heads)"; cur=""
while IFS="$(printf '\t')" read -r name url ref group _; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$group" = "core" ] || continue
  sha="$(git ls-remote "$url" "refs/heads/$ref" 2>/dev/null | cut -c1-12)"
  [ -n "$sha" ] || continue
  cur="$cur$name=$sha "
  old="$(printf '%s' "$prev" | tr ' ' '\n' | sed -n "s/^$name=//p")"
  if [ -n "$old" ] && [ "$old" != "$sha" ]; then
    detail "$name $ref moved $old -> $sha (devops refs sync $name; git -C .references/$name log --oneline $old..$sha)"
  fi
done < "$REPOS"
[ -n "$cur" ] && cstate_set heads "$cur"

# 4. structsd master vs the deployed commit
dep="$(inv_net '.binary.git_commit')"
if [ -n "$dep" ] && [ -d "$DEVOPS_ROOT/.references/structsd/.git" ]; then
  ahead="$(git -C "$DEVOPS_ROOT/.references/structsd" rev-list --count "$dep..origin/master" 2>/dev/null || true)"
  [ -n "$ahead" ] && [ "$ahead" -gt 0 ] && detail "structsd origin/master is $ahead commit(s) past the deployed ${dep:0:7} (as of the last refs sync)"
fi

# 5. pinned source branches whose commit already landed on the default branch
for s in $(inv_sites); do
  n="$(yq '(.sources // []) | length' "$(inv_site_file "$s")")"; i=0
  while [ "$i" -lt "$n" ]; do
    repo="$(inv_q "$s" ".sources[$i].repo")"; commit="$(inv_q "$s" ".sources[$i].commit")"
    reason="$(inv_q "$s" ".sources[$i].pin_reason")"; i=$((i + 1))
    [ -n "$commit" ] && [ -n "$reason" ] || continue
    gh_repo="$(url_of "$repo" | sed -E 's#https://github.com/##; s#\.git$##')"
    def="$(awk -F'\t' -v n="$repo" '$1 == n {print $3}' "$REPOS")"
    st="$(curl -sS -m 15 "https://api.github.com/repos/$gh_repo/compare/${def:-main}...$commit" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)"
    case "$st" in
      behind|identical) detail "$s: $repo pin $commit is now on ${def:-main}; the pin ($reason) can be released" ;;
      ahead|diverged)   detail "ok: $s: $repo pin $commit not yet on ${def:-main}" ;;
    esac
  done
done
check_finish "no new structsd release or image; inventory pins current"
