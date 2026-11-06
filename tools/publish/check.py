#!/usr/bin/env python3
"""Fail if a publishable framework file mentions the operator's own inventory.

    check.py              scan; exit 1 on any finding
    check.py --markers    print the markers collected from the inventory
    check.py --files      print the files that would be published

Publishable = what `git add -A` would pick up in the framework root (all
.gitignore files apply; your global excludes do not, so the scan errs wide).
Markers come from the configured inventory: site and host ids, site names,
hostnames, IPs, addresses, node ids, GA ids, contact emails, non-default source
refs, the overlay network.yaml, plus any lines in <inventory>/publish-markers.txt.
Values in networks/*.yaml are public by definition. Allow a specific hit with a
line in .publish-allow: `MARKER` or `PATH-GLOB<TAB>MARKER`.
"""
from __future__ import annotations

import fnmatch
import ipaddress
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "inventory"))
from invlib import INV, ROOT, load_inventory, load_yaml  # noqa: E402

FQDN = re.compile(r"(?<![\w@.-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})(?![\w-])", re.I)
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.]*\d)")
BECH32 = re.compile(r"\bstructs(?:valoper|valcons|pub)?1[02-9ac-hj-np-z]{38,}\b")
GA = re.compile(r"\bG-[A-Z0-9]{8,12}\b")
EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b")
NODE_ID = re.compile(r"\b[0-9a-f]{40}\b")
TLDS = {"com", "net", "org", "io", "app", "ai", "dev", "energy", "network", "xyz", "gg", "co", "cloud", "me",
        "info", "tech", "games", "game", "zone", "online", "site", "space", "world", "live", "link", "host",
        "us", "uk", "de", "ca", "eu", "fr", "nl", "jp", "kr", "br", "au", "ch", "se", "pl", "in", "ru", "cn"}
RESERVED_DOMAINS = re.compile(r"(^|\.)(example\.(com|net|org)|invalid|test|localhost)$")
DEFAULT_REFS = {"main", "master", "develop", "dev", "latest", "head", "HEAD"}
GENERIC_IDS = {"local", "localhost", "hub", "host", "node", "main", "web", "guild", "public", "chain", "validator"}
USER_PATH = re.compile(r"/Users/(?!<|\$|you\b|me\b|example\b)[A-Za-z0-9._-]+/")
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz", ".tgz", ".woff", ".woff2", ".ttf"}


MD_LINK = re.compile(r"\]\(([^)\s#]+)")


def is_inside(path: Path, base: Path) -> bool:
    try:
        path.resolve().relative_to(base.resolve())
        return True
    except ValueError:
        return False


def strings(node):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
    elif node is not None and not isinstance(node, bool):
        yield str(node)


def public_ip(s: str) -> bool:
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return False
    return not (ip.is_private or ip.is_loopback or ip.is_unspecified or ip.is_link_local or ip.is_reserved)


def sweep(text: str):
    """Identifying values inside a free-form string."""
    for m in FQDN.finditer(text):
        v = m.group(1).lower()
        if v.rsplit(".", 1)[-1] in TLDS and not RESERVED_DOMAINS.search(v):
            yield v, "hostname"
    for m in IPV4.finditer(text):
        if public_ip(m.group(1)):
            yield m.group(1), "ip"
    for m in EMAIL.finditer(text):
        dom = m.group(0).rsplit("@", 1)[1].lower()
        if dom.rsplit(".", 1)[-1] in TLDS and not RESERVED_DOMAINS.search(dom):
            yield m.group(0), "email"
    for rx, kind in ((BECH32, "address"), (GA, "analytics id"), (NODE_ID, "node id / commit")):
        for m in rx.finditer(text):
            yield m.group(0), kind


def collect_markers(net_overlay: dict, sites: dict) -> dict[str, str]:
    out: dict[str, str] = {}

    def add(v, why):
        v = (v or "").strip()
        if len(v) >= 4 and v.lower() not in GENERIC_IDS:
            out.setdefault(v, why)

    for sid, s in sites.items():
        add(sid, f"site id ({sid})")
        if s.get("name") and s.get("name") != sid:
            add(str(s["name"]), f"site name ({sid})")
        for h in (s.get("hosts") or []):
            add(str(h.get("id") or ""), f"host id ({sid})")
            if "@" in str(h.get("ssh") or ""):
                add(str(h["ssh"]), f"ssh target ({sid})")
        for src in (s.get("sources") or []):
            ref = str(src.get("ref") or "")
            if ref and ref not in DEFAULT_REFS and not re.fullmatch(r"v?\d+(\.\d+)*", ref):
                add(ref, f"source ref ({sid} {src.get('repo')})")
        for text in strings(s):
            for v, kind in sweep(text):
                add(v, f"{kind} ({sid})")
    for text in strings(net_overlay):
        for v, kind in sweep(text):
            add(v, f"{kind} (network.yaml)")
    extra = INV / "publish-markers.txt"
    if extra.is_file():
        for line in extra.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.setdefault(line, "publish-markers.txt")
    return out


def public_values() -> set[str]:
    vals: set[str] = set()
    for f in sorted((ROOT / "networks").glob("*.yaml")):
        for text in strings(load_yaml(f)):
            vals.add(text)
            vals.update(v for v, _ in sweep(text))
    return vals


def load_allow() -> list[tuple[str, str]]:
    f = ROOT / ".publish-allow"
    rules = []
    if f.is_file():
        for line in f.read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            glob, _, marker = line.partition("\t") if "\t" in line else ("*", "", line)
            rules.append((glob.strip(), marker.strip()))
    return rules


def publishable() -> list[str]:
    if (ROOT / ".git").exists():
        p = subprocess.run(["git", "-c", "core.excludesFile=/dev/null", "-C", str(ROOT), "ls-files",
                            "--cached", "--others", "--exclude-standard", "-z"],
                           capture_output=True, text=True, check=True)
        return sorted(f for f in p.stdout.split("\0") if f and (ROOT / f).is_file())
    scratch = Path(os.environ.get("DEVOPS_STATE") or ROOT / "state")
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch, prefix="publish-check.") as td:
        subprocess.run(["git", "init", "-q", "--template=", td], check=True)
        p = subprocess.run(
            ["git", "-c", "core.excludesFile=/dev/null", f"--git-dir={td}/.git", f"--work-tree={ROOT}",
             "ls-files", "--others", "--exclude-standard", "-z"],
            capture_output=True, text=True, check=True, cwd=ROOT)
    return sorted(f for f in p.stdout.split("\0") if f)


def pattern(marker: str, why: str) -> re.Pattern:
    flags = re.I if why.startswith(("site name", "hostname", "email", "publish-markers")) else 0
    return re.compile(r"(?<![\w-])" + re.escape(marker) + r"(?![\w-])", flags)


def main(argv: list[str]) -> int:
    files = publishable()
    if "--files" in argv:
        print("\n".join(files))
        return 0
    net_overlay = load_yaml(INV / "network.yaml") if (INV / "network.yaml").is_file() else {}
    _, sites = load_inventory()
    public = public_values()
    markers = {m: why for m, why in collect_markers(net_overlay, sites).items() if m not in public}
    if "--markers" in argv:
        for m, why in sorted(markers.items(), key=lambda kv: kv[1]):
            print(f"{m}\t{why}")
        return 0

    problems: list[str] = []
    try:
        inv_rel = INV.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        inv_rel = None
    if inv_rel is not None and any(f == inv_rel or f.startswith(inv_rel + "/") for f in files):
        problems.append(f"{inv_rel}/ is publishable: it must be git-ignored by the framework "
                        "(or point DEVOPS_INVENTORY at your private inventory, not at examples/)")
    for f in (".devops.env",):
        if f in files:
            problems.append(f"{f} is publishable: add it to .gitignore")

    allow = load_allow()
    pats = [(m, why, pattern(m, why)) for m, why in markers.items()]
    hits = 0
    for rel in files:
        if Path(rel).suffix.lower() in SKIP_EXT:
            continue
        allowed = {m for g, m in allow if fnmatch.fnmatch(rel, g)}
        for m, why, rx in pats:
            if m not in allowed and rx.search(rel):
                problems.append(f"{rel}: file name contains {m}  [{why}]")
                hits += 1
        try:
            lines = (ROOT / rel).read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(lines, 1):
            if rel.endswith(".md"):
                for href in MD_LINK.findall(line):
                    if not re.match(r"^[a-z]+:", href) and is_inside((ROOT / rel).parent / href, INV):
                        problems.append(f"{rel}:{n}: links into the inventory ({href}); a public clone has no such file")
            for m, why, rx in pats:
                if m not in allowed and rx.search(line):
                    problems.append(f"{rel}:{n}: {m}  [{why}]")
                    hits += 1
            um = USER_PATH.search(line)
            if um and "/Users/" not in allowed:
                problems.append(f"{rel}:{n}: home directory path {um.group(0)}")
                hits += 1

    scan = subprocess.run([sys.executable, "-B", str(ROOT / "tools/secrets/scan.py"),
                           *[str(ROOT / f) for f in files]], capture_output=True, text=True)
    if scan.returncode != 0:
        problems += [f"secrets: {l}" for l in scan.stdout.splitlines() if l.strip()]

    for p in problems:
        print(p)
    print(f"publish-check: {len(files)} publishable file(s), {len(markers)} marker(s) from "
          f"{INV}, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
