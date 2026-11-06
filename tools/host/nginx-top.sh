# Host side of devops debug nginx-top (streamed). Read-only.
# Env: STRUCTS_WEBAPP_CACHE_CONTAINER TOP_SINCE TOP_N
set +e
c="${STRUCTS_WEBAPP_CACHE_CONTAINER:-}"
[ -n "$c" ] || { echo "no structs-webapp-cache container for this site" >&2; exit 1; }
clog "$c" --since "${TOP_SINCE:-1h}" | python3 -c '
import collections, re, sys
N = int(sys.argv[1])
LINE = re.compile(r"^(\S+) \S+ \S+ \[([^\]]+)\] \"(\S+) (\S+)[^\"]*\" (\d{3}) (\d+|-) \"([^\"]*)\" \"([^\"]*)\"(.*)$")
ID = re.compile(r"/(\d+-\d+|\d+|[0-9a-f]{16,}|structs1[0-9a-z]{20,})(?=/|$)")
paths, status, uas, ips, bytes_by, minutes, pages = (collections.Counter() for _ in range(7))
page_nums = collections.defaultdict(set)
poll = collections.Counter()
poll_urls = collections.defaultdict(set)
total = other = 0
for raw in sys.stdin:
    m = LINE.match(raw)
    if not m:
        other += 1
        continue
    total += 1
    ip, ts, method, url, st, size, _ref, ua, rest = m.groups()
    path = url.split("?", 1)[0]
    norm = ID.sub("/{id}", path)
    key = f"{method} {norm}"
    paths[key] += 1
    status[st] += 1
    uas[ua[:90]] += 1
    xff = re.search(r"\"(\d+\.\d+\.\d+\.\d+)[,\"]", rest)
    client = xff.group(1) if xff else ip
    ips[client] += 1
    poll[(client, key)] += 1
    if len(poll_urls[(client, key)]) < 5000:
        poll_urls[(client, key)].add(url)
    bytes_by[key] += 0 if size == "-" else int(size)
    minutes[ts[:17]] += 1
    pm = re.search(r"/page/(\d+)", path) or re.search(r"[?&](?:page|offset)=(\d+)", url)
    if pm:
        page_nums[(ua[:90], ID.sub("/{id}", re.sub(r"/page/\d+", "/page/{n}", path)))].add(pm.group(1))
if not total:
    print(f"no access-log lines parsed ({other} other lines); is access logging on?")
    sys.exit(0)
def top(title, counter, n=N, fmt=lambda k, v: f"{v:>7}  {k}"):
    print(f"== {title}")
    for k, v in counter.most_common(n):
        print(fmt(k, v))
    print()
span = len(minutes) or 1
print(f"requests={total} minutes={span} avg_per_min={total // span} peak_per_min={max(minutes.values())} unparsed={other}\n")
top("top paths (ids collapsed)", paths)
top("status codes", status, 10)
top("user agents", uas, 10)
top("client addresses (nginx sees Caddy unless X-Forwarded-For is logged)", ips, 10)
top("bytes by path", bytes_by, 10, lambda k, v: f"{v / 1e6:>8.1f} MB  {k}")
print("== scraper loops (one agent walking many pages of one listing)")
flagged = 0
for (ua, p), nums in sorted(page_nums.items(), key=lambda kv: -len(kv[1])):
    if len(nums) >= 20:
        flagged += 1
        print(f"{len(nums):>7} pages  {p}  ua={ua}")
    if flagged >= 10:
        break
if not flagged:
    print("      none")
print("\n== heavy pollers (one client on one route, >= 20% of requests or >= 200)")
flagged = 0
for (client, key), n in poll.most_common(10):
    if n < 200 and n < total * 0.2:
        break
    flagged += 1
    print(f"{n:>7}  {client}  {key}  distinct_urls={len(poll_urls[(client, key)])} per_min={n // span}")
if not flagged:
    print("      none")
ua_share = uas.most_common(1)[0]
if ua_share[1] > total * 0.3:
    print(f"\nnote: one user agent made {100 * ua_share[1] // total}% of requests: {ua_share[0]}")
print("\ncache status is not in the combined log format; use devops debug http-trace for X-Cache-Status")
' "${TOP_N:-15}"
