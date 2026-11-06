# Host probe (streamed after _prelude.sh). Env: DISK_PATHS (space-separated). Read-only.
echo "nproc=$(nproc)"
read -r l1 l5 l15 _ < /proc/loadavg
echo "load1=$l1"; echo "load5=$l5"; echo "load15=$l15"
awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
     END {print "mem_total_kb=" t; print "mem_avail_kb=" a; print "swap_total_kb=" st; print "swap_used_kb=" st - sf}' /proc/meminfo
i=0
for p in ${DISK_PATHS:-/}; do
  if [ -e "$p" ]; then
    df -P -B1 "$p" | awk -v i="$i" -v p="$p" 'NR==2 {gsub("%","",$5); print "disk" i "_path=" p; print "disk" i "_used=" $3; print "disk" i "_avail=" $4; print "disk" i "_used_pct=" $5}'
    df -Pi "$p" | awk -v i="$i" 'NR==2 {gsub("%","",$5); print "disk" i "_inode_pct=" $5}'
  else
    echo "disk${i}_path=$p"; echo "disk${i}_missing=1"
  fi
  i=$((i + 1))
done
echo "disks=$i"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
echo "oom_1h=$(journalctl -k --since '1 hour ago' --no-pager 2>/dev/null | grep -ci 'out of memory' || true)"
echo "docker=$(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo down)"
echo "top_cpu=$(ps -eo pcpu,comm --sort=-pcpu --no-headers | head -3 | awk '{printf "%s(%s%%) ", $2, $1}')"
