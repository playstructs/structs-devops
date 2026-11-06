#!/usr/bin/env bash
# Daily: fetch the core .references clones (hub-local), then report new
# structsd tags, image digests, repo heads that moved and releasable pins.
# Includes the commit subjects that landed in each core repo since yesterday.
. "$DEVOPS_ROOT/crons/jobs/_job.sh"
job_begin new-updates

before="$(mkstate jobs)/new-updates.heads"
now_heads=""
while IFS="$(printf '\t')" read -r name _ ref group _; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$group" = "core" ] || continue
  d="$DEVOPS_REFS/$name"
  [ -d "$d/.git" ] || continue
  now_heads="$now_heads$name=$(git -C "$d" rev-parse -q --verify "origin/$ref" 2>/dev/null) "
done < "$DEVOPS_REFS/repos.tsv"

"$DEVOPS_ROOT/tools/refs/refs.sh" sync >/dev/null 2>&1 || job_log "> refs sync failed (offline?)"

job_log "## Commits since the previous run"
moved=""
while IFS="$(printf '\t')" read -r name _ ref group _; do
  case "$name" in ""|\#*) continue ;; esac
  [ "$group" = "core" ] || continue
  d="$DEVOPS_REFS/$name"
  [ -d "$d/.git" ] || continue
  old="$(printf '%s' "$now_heads" | tr ' ' '\n' | sed -n "s/^$name=//p")"
  new="$(git -C "$d" rev-parse -q --verify "origin/$ref" 2>/dev/null)"
  [ -n "$old" ] && [ -n "$new" ] && [ "$old" != "$new" ] || continue
  moved="$moved $name"
  job_log ""
  job_log "### $name ($ref)"
  job_log '```'
  job_log "$(git -C "$d" log --oneline --no-merges "$old..$new" 2>/dev/null | head -30)"
  job_log '```'
done < "$DEVOPS_REFS/repos.tsv"
[ -z "$moved" ] && job_log "none"
printf '%s\n' "$now_heads" > "$before"

rc=0
run_group any network "new-releases" || rc=$?
[ -n "$moved" ] && notify INFO "upstream changes" "core repos with new commits:$moved (report: ${JOB_REPORT#"$DEVOPS_ROOT"/})"
job_end
exit "$rc"
