# Host probe (streamed). Env: GROWTH_PATH. Read-only (du can take a few seconds).
p="${GROWTH_PATH:?}"
echo "data_bytes=$(du -sb "$p/data" 2>/dev/null | cut -f1)"
df -P -B1 "$p" | awk 'NR==2 {print "avail=" $4; print "size=" $2}'
