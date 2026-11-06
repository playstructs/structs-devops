#!/usr/bin/env python3
"""Look for secret material in workspace files.

    scan.py                     the workspace and the inventory (minus ignored dirs)
    scan.py --staged [--repo D] files staged for commit in repo D (default: the
                                workspace); used by the pre-commit hooks
    scan.py PATH...             specific files or directories

Findings print as path:line: rule: <first 4 chars>... and never the value.
Exit 1 when anything is found. Allow a known-safe line by adding a regex to
tools/secrets/scan-allow.txt, or for your own files to
$DEVOPS_INVENTORY/scan-allow.txt (matched against "path:line-text").
"""
import os
import re
import subprocess
import sys

ROOT = os.environ.get("DEVOPS_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INV = os.path.abspath(os.path.join(ROOT, os.environ.get("DEVOPS_INVENTORY") or "inventory"))
SKIP_DIRS = {".git", ".references", "state", "local", "node_modules", "dist", "__pycache__", ".venv"}
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz", ".tgz", ".woff", ".woff2", ".ttf"}

PLACEHOLDER = re.compile(
    r"^(\$\{?[A-Za-z_]|\$\(|<[^>]*>|x{3,}|\*{3,}|\.\.\.|changeme|change-me|example|redacted|placeholder|"
    r"your[-_]|none$|null$|true$|false$|empty$|unset$|set$|present$|n/a$|todo|tbd|readonly$)",
    re.I,
)
ASSIGN = re.compile(
    r"\b([A-Z0-9_]*(MNEMONIC|SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|PRIVATE_KEY|ENCRYPTION_KEY|ACCESS_KEY|CLIENT_SECRET)[A-Z0-9_]*)"
    r"\s*[:=]\s*[\"']?([^\s\"'#,;()]{8,})(?!\()"
)
RULES = [
    ("private-key-pem", re.compile(r"-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("cosmos-priv-key-json", re.compile(r"\"priv_key\"\s*:\s*\{[^}]*\"value\"\s*:\s*\"[A-Za-z0-9+/=]{40,}")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("matrix-access-token", re.compile(r"\bsyt_[A-Za-z0-9_]{20,}")),
    ("mas-token", re.compile(r"\bm[ac]t_[A-Za-z0-9]{20,}")),
    ("dockerhub-pat", re.compile(r"\bdckr_pat_[A-Za-z0-9_-]{20,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("discord-webhook", re.compile(r"discord(app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}")),
]
MNEMONIC_WORDS = re.compile(r"(?<![A-Za-z])((?:[a-z]{3,8} ){11}(?:[a-z]{3,8} ){0,12}[a-z]{3,8})(?![A-Za-z])")


def allowlist():
    pats = []
    for p in (os.path.join(ROOT, "tools", "secrets", "scan-allow.txt"), os.path.join(INV, "scan-allow.txt")):
        if os.path.exists(p):
            for line in open(p, encoding="utf-8"):
                line = line.strip()
                if line and not line.startswith("#"):
                    pats.append(re.compile(line))
    return pats


def files_from_args(args):
    if "--staged" in args:
        i = args.index("--repo") if "--repo" in args else -1
        repo = args[i + 1] if 0 <= i < len(args) - 1 else ROOT
        out = subprocess.run(["git", "-C", repo, "diff", "--cached", "--name-only", "--diff-filter=ACM", "-z"],
                             capture_output=True, text=True, check=False).stdout
        top = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False).stdout.strip() or repo
        return [os.path.join(top, f) for f in out.split("\0") if f]
    targets = [a for a in args if not a.startswith("--")]
    if not targets:
        targets = [ROOT]
        if os.path.isdir(INV) and not (INV + os.sep).startswith(os.path.abspath(ROOT) + os.sep):
            targets.append(INV)
    found = []
    for t in targets:
        if os.path.isfile(t):
            found.append(t)
            continue
        for d, dirs, fs in os.walk(t):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            for f in fs:
                found.append(os.path.join(d, f))
    return found


def redact(s):
    return s[:4] + "..." if len(s) > 4 else "..."


def scan_file(path, allow):
    if os.path.splitext(path)[1].lower() in SKIP_EXT or not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except (UnicodeDecodeError, OSError):
        return []
    rel = os.path.relpath(path, ROOT)
    hits = []
    for n, line in enumerate(lines, 1):
        key = f"{rel}:{line.rstrip()}"
        if any(p.search(key) for p in allow):
            continue
        for name, rx in RULES:
            m = rx.search(line)
            if m:
                hits.append((rel, n, name, redact(m.group(0))))
        for m in ASSIGN.finditer(line):
            val = m.group(3)
            if PLACEHOLDER.search(val) or val.startswith(("http://", "https://", "/", "./")):
                continue
            if re.fullmatch(r"[a-z_.-]+", val) and len(val) < 16:
                continue  # an identifier such as a key name or service name
            if re.fullmatch(r"[A-Za-z_]\w*(\.[A-Za-z_]\w*)+", val):
                continue  # a code reference such as re.compile or os.environ
            hits.append((rel, n, f"assignment:{m.group(1)}", redact(val)))
        if "mnemonic" in line.lower() or "seed" in line.lower():
            m = MNEMONIC_WORDS.search(line)
            if m and len(m.group(1).split()) in (12, 15, 18, 21, 24):
                hits.append((rel, n, "mnemonic-words", redact(m.group(1))))
    return hits


def main():
    allow = allowlist()
    hits = []
    for f in files_from_args(sys.argv[1:]):
        hits.extend(scan_file(f, allow))
    for rel, n, rule, red in hits:
        print(f"{rel}:{n}: {rule}: {red}")
    if hits:
        print(f"secrets scan: {len(hits)} finding(s). Move the value to its host and keep a pointer "
              f"(docs/secrets.md), or allow-list a false positive in scan-allow.txt (tools/secrets/ or your inventory).", file=sys.stderr)
        return 1
    print("secrets scan: clean", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
