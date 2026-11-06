#!/usr/bin/env bash
# app-toml-overrides.sh --check|--apply
# network-config.sh re-templates app.toml whenever the docker-config marker
# changes (typically a recreate with a new image). This re-applies the site's
# overrides (sites/<site>/app-toml.overrides). Changes take effect on the next
# structsd restart, which is a separate tier-2 step.
. "$(dirname "$0")/_bundle.sh"

MODE="${1:---check}"
OVR="$SITE_DIR/app-toml.overrides"
VOL_MP="$(docker volume inspect "${NODE_VOLUME:-structsd-chaindata}" --format '{{.Mountpoint}}')"
APP="${APP_TOML:-$VOL_MP/config/app.toml}"
[ -f "$OVR" ] || { echo "no overrides for $SITE_ID ($OVR)" >&2; exit 2; }
[ -f "$APP" ] || { echo "FATAL: $APP not found" >&2; exit 1; }

python3 - "$APP" "$OVR" "$MODE" <<'PY'
import difflib, re, shutil, sys
from datetime import datetime
app, ovr, mode = sys.argv[1:4]
want = []
for raw in open(ovr):
    l = raw.strip()
    if not l or l.startswith("#"):
        continue
    m = re.match(r"^(-|\[[^\]]+\])\s+([A-Za-z0-9_.-]+)\s*=\s*(.+)$", l)
    if not m:
        sys.exit(f"bad override line: {l}")
    want.append((None if m[1] == "-" else m[1], m[2], m[3].strip()))

orig = open(app).read().split("\n")
lines = list(orig)

def locate(section, key):
    cur, first_header = None, None
    for i, l in enumerate(lines):
        if l.startswith("["):
            cur = l.strip()
            if first_header is None:
                first_header = i
            continue
        if cur == section and re.match(rf"^{re.escape(key)}\s*=", l):
            return i, first_header
    return None, first_header

drift = []
for section, key, val in want:
    i, first_header = locate(section, key)
    where = section or "top-level"
    if i is not None:
        have = lines[i].split("=", 1)[1].strip()
        if have != val:
            drift.append(f"{where} {key}: have {have} want {val}")
            lines[i] = f"{key} = {val}"
        continue
    drift.append(f"{where} {key}: missing, want {val}")
    if section is None:
        lines.insert(first_header if first_header is not None else len(lines), f"{key} = {val}")
    elif section in [l.strip() for l in lines if l.startswith("[")]:
        h = next(j for j, l in enumerate(lines) if l.startswith("[") and l.strip() == section)
        lines.insert(h + 1, f"{key} = {val}")
    else:
        lines += ["", section, f"{key} = {val}"]

for d in drift:
    print("  DRIFT " + d)
if mode == "--check":
    print(f"APPTOML file={app} drift={len(drift)}")
    sys.exit(1 if drift else 0)
if not drift:
    print(f"APPTOML file={app} drift=0 (nothing to apply)")
    sys.exit(0)
bak = f"{app}.bak.{datetime.now():%Y%m%dT%H%M%S}"
shutil.copy2(app, bak)
print(f"  backup -> {bak}")
with open(app, "w") as f:
    f.write("\n".join(lines))
sys.stdout.writelines(difflib.unified_diff([l + "\n" for l in orig], [l + "\n" for l in lines], bak, app))
print(f"APPTOML file={app} applied={len(drift)} restart-needed=yes")
PY
