#!/usr/bin/env bash
# devops cron list                          [0] jobs, schedules, installed?, last run
# devops cron status                        [0] same as list, plus overdue/gap flags
# devops cron run <job>                     [0] run a job now (what launchd/cron calls)
# devops cron logs <job> [n]                [0] tail the job's launchd/cron log
# devops cron install [job...] [--crontab]  [1] hub only: launchd agents (macOS) or crontab lines
# devops cron uninstall [job...]            [1] remove them again
set -uo pipefail
. "$DEVOPS_ROOT/lib/common.sh"
. "$DEVOPS_ROOT/lib/gate.sh"
need yq

SCHED="$DEVOPS_ROOT/crons/schedules.yaml"
LOGD="$(mkstate logs)"
SLUG="$(printf '%s' "$DEVOPS_ROOT" | sha_short | cut -c1-8)"
LABEL_PREFIX="io.structs-devops.$SLUG"
AGENTS="$HOME/Library/LaunchAgents"
MARK="# structs-devops:$SLUG"

jobs_all() { yq -r '.jobs | keys | .[]' "$SCHED"; }
jq_job() { J="$1" yq -r ".jobs[strenv(J)].$2 // \"\"" "$SCHED"; }
plist_of() { printf '%s/%s.%s.plist' "$AGENTS" "$LABEL_PREFIX" "$1"; }

installed() {
  if [ "$(uname)" = "Darwin" ] && [ -z "${USE_CRONTAB:-}" ]; then [ -f "$(plist_of "$1")" ]
  else crontab -l 2>/dev/null | grep -F "$MARK" | grep -q " run $1 "; fi
}

last_run() {
  local f="$DEVOPS_STATE/jobs/$1.last" t
  [ -f "$f" ] || { echo "never"; return; }
  t="$(cat "$f")"
  echo "$(( ($(now_epoch) - t) / 60 ))m ago"
}

xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

plist_xml() {
  local job="$1" iv cal path root logd
  iv="$(jq_job "$job" launchd.interval)"
  path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  root="$(xml_esc "$DEVOPS_ROOT")"; logd="$(xml_esc "$LOGD")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL_PREFIX.$job</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$root/crons/cron.sh</string>
    <string>run</string>
    <string>$job</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path</string>
    <key>DEVOPS_ROOT</key><string>$root</string>
    <key>DEVOPS_CRON</key><string>1</string>
  </dict>
  <key>WorkingDirectory</key><string>$root</string>
  <key>StandardOutPath</key><string>$logd/cron-$job.log</string>
  <key>StandardErrorPath</key><string>$logd/cron-$job.log</string>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
EOF
  if [ -n "$iv" ]; then
    printf '  <key>StartInterval</key><integer>%s</integer>\n' "$iv"
  else
    printf '  <key>StartCalendarInterval</key>\n  <dict>\n'
    for k in Weekday Hour Minute; do
      cal="$(jq_job "$job" "launchd.calendar.$k")"
      [ -n "$cal" ] && printf '    <key>%s</key><integer>%s</integer>\n' "$k" "$cal"
    done
    printf '  </dict>\n'
  fi
  printf '</dict>\n</plist>\n'
}

sub="${1:-list}"; [ $# -gt 0 ] && shift
case "$sub" in
  list|status)
    printf '%-15s %-10s %-10s %-12s %s\n' JOB INSTALLED LAST EVERY DESCRIPTION
    for j in $(jobs_all); do
      iv="$(jq_job "$j" interval_seconds)"
      inst=no; installed "$j" && inst=yes
      lr="$(last_run "$j")"
      flag=""
      if [ "$sub" = status ] && [ -f "$DEVOPS_STATE/jobs/$j.last" ]; then
        age=$(( $(now_epoch) - $(cat "$DEVOPS_STATE/jobs/$j.last") ))
        [ "$age" -gt $(( iv * 2 )) ] && flag=" OVERDUE"
      fi
      printf '%-15s %-10s %-10s %-12s %s%s\n' "$j" "$inst" "$lr" "$((iv / 60))m" "$(jq_job "$j" description | cut -c1-70)" "$flag"
    done
    if [ "$sub" = status ] && [ "$(uname)" = "Darwin" ]; then
      case "$DEVOPS_ROOT" in
        "$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Downloads"*)
          warn "workspace is under a macOS-protected folder; launchd jobs need Full Disk Access for /bin/bash (crons/README.md#macos-privacy)" ;;
      esac
    fi ;;
  run)
    job="${1:-}"; [ -n "$job" ] || usage_die "usage: devops cron run <job>"
    s="$(jq_job "$job" script)"; [ -n "$s" ] || usage_die "unknown job $job (devops cron list)"
    printf '%s run %s\n' "$(iso_now)" "$job" >&2
    exec bash "$DEVOPS_ROOT/crons/jobs/$s" ;;
  logs)
    job="${1:-}"; [ -n "$job" ] || usage_die "usage: devops cron logs <job> [n]"
    tail -n "${2:-60}" "$LOGD/cron-$job.log" 2>/dev/null || echo "no log yet for $job" ;;
  install|uninstall)
    sel=""; USE_CRONTAB=""
    for a in "$@"; do case "$a" in --crontab) USE_CRONTAB=1 ;; *) sel="$sel $a" ;; esac; done
    [ "$(uname)" = "Darwin" ] || USE_CRONTAB=1
    [ -n "$sel" ] || sel="$(jobs_all | tr '\n' ' ')"
    for j in $sel; do [ -n "$(jq_job "$j" script)" ] || usage_die "unknown job $j"; done
    if [ -z "$USE_CRONTAB" ]; then
      mkdir -p "$AGENTS"
      for j in $sel; do
        p="$(plist_of "$j")"
        if [ "$sub" = install ]; then
          if [ -n "${DEVOPS_DRY_RUN:-}" ]; then echo "--- $p"; plist_xml "$j"; continue; fi
          launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
          plist_xml "$j" > "$p"
          launchctl bootstrap "gui/$(id -u)" "$p" && ok "installed $j ($p)"
        else
          [ -n "${DEVOPS_DRY_RUN:-}" ] && { echo "would remove $p"; continue; }
          launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
          rm -f "$p" && ok "removed $j"
        fi
      done
    else
      cur="$(crontab -l 2>/dev/null || true)"
      keep="$cur"
      for j in $sel; do keep="$(printf '%s\n' "$keep" | grep -vF "$MARK run $j" || true)"; done
      if [ "$sub" = install ]; then
        for j in $sel; do
          keep="$keep
$(jq_job "$j" cron) cd $(printf '%q' "$DEVOPS_ROOT") && PATH=/usr/local/bin:/usr/bin:/bin DEVOPS_CRON=1 bash crons/cron.sh run $j >> $(printf '%q' "$LOGD/cron-$j.log") 2>&1 $MARK run $j "
        done
      fi
      if [ -n "${DEVOPS_DRY_RUN:-}" ]; then printf '%s\n' "$keep"; exit 0; fi
      printf '%s\n' "$keep" | sed '/^$/d' | crontab - && ok "crontab updated ($sub:$sel)"
    fi
    [ -n "${DEVOPS_DRY_RUN:-}" ] && exit 0
    audit "TIER1 cron $sub jobs:$sel"
    [ "$sub" = install ] && note "jobs notify via DEVOPS_NOTIFY in .devops.env (now: ${DEVOPS_NOTIFY:-stdout}); see crons/README.md" ;;
  *) usage_die "usage: devops cron list|status|run <job>|logs <job>|install|uninstall" ;;
esac
