#!/usr/bin/env python3
"""Validate inventory/ against the structs-devops/site/v1 format.

Errors exit 1. Warnings (stale last_verified, unverified fields, critical
secrets without backup) are printed but do not fail.
"""
from __future__ import annotations

import datetime as dt
import re
import sys

from invlib import INV, ROOT, get, host_index, load_inventory, site_dir

KINDS = {"guild", "public-node", "local"}
CRIT = {"critical", "high", "medium", "low"}
STEP_TYPES = {"ssh", "tool", "local", "backup", "check", "confirm"}
SCHEMES = ("host-env:", "host-file:", "host-volume:", "local-env:")
MNEMONIC = re.compile(r"^(?:[a-z]{3,8} ){11}(?:[a-z]{3,8} ){0,12}[a-z]{3,8}$")
PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")
SECRETY_KEY = re.compile(r"(password|passwd|secret|mnemonic|token|private_?key)$", re.I)

errors: list[str] = []
warnings: list[str] = []


def e(msg):
    errors.append(msg)


def w(msg):
    warnings.append(msg)


def walk(node, path, sid):
    """Flag values that look like secrets anywhere outside pointer fields."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}" if path else k
            if isinstance(v, str) and SECRETY_KEY.search(str(k)) and v and not v.startswith(SCHEMES) \
                    and not path.startswith("secrets") and k not in ("secret",):
                e(f"{sid}: {p} looks like a secret value; store a pointer under secrets: instead")
            walk(v, p, sid)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", sid)
    elif isinstance(node, str):
        s = node.strip()
        if MNEMONIC.match(s) and len(s.split()) in (12, 15, 18, 21, 24):
            e(f"{sid}: {path} looks like a mnemonic")
        if PEM.search(s):
            e(f"{sid}: {path} contains a PEM private key")


def check_network(net):
    for key in ("chain_id", "endpoints.rpc", "endpoints.lcd", "binary.version", "binary.since_height"):
        if get(net, key) in (None, ""):
            e(f"network.yaml: missing {key}")
    names = [u.get("name") for u in net.get("upgrades") or []]
    if get(net, "binary.version") not in names:
        w(f"network.yaml: binary.version {get(net, 'binary.version')} is not in upgrades[]")


def overlay_exists(sid, rel, kind):
    if rel.startswith("@shared/"):
        base = INV / "shared" / "patches" / ("snippets" if kind == "snippet" else "overlay")
        return (base / rel[len("@shared/"):]).is_file()
    base = site_dir(sid) / "patches" / ("snippets" if kind == "snippet" else "overlay")
    return (base / rel).is_file()


def check_patches(sid, s):
    for h in get(s, "patches.pre_helpers") or []:
        if not any((d / "tools" / "host" / f"{h}.sh").is_file() for d in (ROOT, INV)):
            e(f"{sid}: patches.pre_helpers {h}: no tools/host/{h}.sh in the framework or the inventory")
    m = get(s, "patches.manifest")
    if not m:
        return
    path = site_dir(sid) / m
    if not path.is_file():
        e(f"{sid}: patches.manifest {m} not found")
        return
    ids = set()
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 6:
            e(f"{sid}: {m}:{n} has {len(cols)} columns (want 6, tab-separated)")
            continue
        pid, kind, target, ov, anchor, verify = cols
        if pid in ids:
            e(f"{sid}: {m}:{n} duplicate patch id {pid}")
        ids.add(pid)
        if kind not in {"overlay", "transform", "transform_all", "snippet", "verify"}:
            e(f"{sid}: {m}:{n} unknown kind {kind}")
        if kind in ("overlay", "snippet") and (ov == "-" or not overlay_exists(sid, ov, kind)):
            e(f"{sid}: {m}:{n} {kind} file missing: {ov}")
        if kind in ("transform", "transform_all", "snippet") and anchor == "-":
            e(f"{sid}: {m}:{n} {kind} needs an anchor")
        if verify == "-" and kind != "transform_all":
            w(f"{sid}: {m}:{n} {pid} has no verify pattern")
        for var in re.findall(r"\$\{([A-Z_]+)\}", target):
            if var not in (s.get("host_env") or {}):
                e(f"{sid}: {m}:{n} target uses ${{{var}}} but host_env has no {var}")


def check_site(sid, s, hosts_idx, net, today):
    if s.get("schema") != "structs-devops/site/v1":
        e(f"{sid}: schema must be structs-devops/site/v1")
    if s.get("id") != sid:
        e(f"{sid}: id '{s.get('id')}' must match the directory name")
    kind = s.get("kind")
    if kind not in KINDS:
        e(f"{sid}: kind must be one of {sorted(KINDS)}")
    for key in ("name", "network", "hosts", "last_verified"):
        if not s.get(key):
            e(f"{sid}: missing {key}")
    if s.get("network") and s.get("network") != net.get("id"):
        e(f"{sid}: network {s.get('network')} does not match network.yaml id {net.get('id')}")

    lv = s.get("last_verified")
    if lv:
        try:
            age = (today - dt.date.fromisoformat(str(lv))).days
            stale = int(get(net, "check_defaults.inventory.stale_days", 30))
            if age > stale:
                w(f"{sid}: last_verified {lv} is {age} days old (re-verify and bump it)")
        except ValueError:
            e(f"{sid}: last_verified must be YYYY-MM-DD")
    for u in s.get("unverified") or []:
        w(f"{sid}: unverified field {u}")

    host_ids = set()
    for h in s.get("hosts") or []:
        hid = h.get("id")
        if not hid or not h.get("ssh"):
            e(f"{sid}: every host needs id and ssh")
            continue
        host_ids.add(hid)
        if len(hosts_idx.get(hid, [])) > 1:
            e(f"{sid}: host id {hid} is used by more than one site")
    if kind == "local" and not any(h.get("ssh") == "local" for h in s.get("hosts") or []):
        e(f"{sid}: local sites need a host with ssh: local")

    stack_ids = set()
    for st in s.get("stacks") or []:
        if not st.get("id") or not st.get("path"):
            e(f"{sid}: every stack needs id and path")
        if st.get("host") not in host_ids:
            e(f"{sid}: stack {st.get('id')} host {st.get('host')} is not a host of this site")
        stack_ids.add(st.get("id"))
    for n in s.get("nodes") or []:
        if n.get("host") not in host_ids:
            e(f"{sid}: node host {n.get('host')} is not a host of this site")
        if not n.get("container"):
            e(f"{sid}: node on {n.get('host')} needs container")

    secrets = s.get("secrets") or {}
    for name, sec in secrets.items():
        ref = (sec or {}).get("ref", "")
        if not ref.startswith(SCHEMES):
            e(f"{sid}: secret {name} ref must start with one of {SCHEMES}")
            continue
        if not ref.startswith("local-env:"):
            href = ref.split(":", 2)[1]
            if href not in hosts_idx:
                e(f"{sid}: secret {name} points at unknown host {href}")
        if ref.startswith("host-env:") and "#" not in ref:
            e(f"{sid}: secret {name} host-env ref needs #KEY")
        if sec.get("criticality") not in CRIT:
            e(f"{sid}: secret {name} criticality must be one of {sorted(CRIT)}")
        for key in ("backup", "rotation"):
            if not sec.get(key):
                e(f"{sid}: secret {name} missing {key}")
        if sec.get("criticality") == "critical" and str(sec.get("backup", "")).lower() == "none":
            w(f"{sid}: critical secret {name} has no off-host backup")

    for acct, a in (get(s, "onchain.accounts") or {}).items():
        if a.get("secret") and a["secret"] not in secrets:
            e(f"{sid}: onchain.accounts.{acct}.secret {a['secret']} is not declared under secrets")
        if not str(a.get("address", "")).startswith(net.get("bech32_prefix", "structs") + "1"):
            e(f"{sid}: onchain.accounts.{acct}.address looks wrong")

    if kind == "guild":
        if not get(s, "onchain.guild.id"):
            e(f"{sid}: guild sites need onchain.guild.id")
        if not s.get("endpoints"):
            e(f"{sid}: guild sites need endpoints")
    if kind == "public-node":
        for key in ("dependents", "endpoints", "tls", "nodes"):
            if not s.get(key):
                e(f"{sid}: public-node sites need {key}")

    for pname, proc in (s.get("procedures") or {}).items():
        steps = (proc or {}).get("steps") or []
        if not steps:
            e(f"{sid}: procedure {pname} has no steps")
        for i, step in enumerate(steps):
            types = STEP_TYPES.intersection(step.keys())
            if len(types) != 1:
                e(f"{sid}: procedure {pname} step {i + 1} needs exactly one of {sorted(STEP_TYPES)}")
            if step.get("stack") and step["stack"] not in stack_ids:
                e(f"{sid}: procedure {pname} step {i + 1} unknown stack {step['stack']}")
            if "tier" in step and step["tier"] not in (0, 1, 2, 3):
                e(f"{sid}: procedure {pname} step {i + 1} tier must be 0-3")

    for ep in s.get("endpoints") or []:
        if not ep.get("id") or not (ep.get("url") or ep.get("tcp")):
            e(f"{sid}: every endpoint needs id and url or tcp")

    check_patches(sid, s)
    walk(s, "", sid)


def main():
    net, sites = load_inventory()
    today = dt.date.today()
    check_network(net)
    hosts_idx = host_index(sites)
    for sid, s in sites.items():
        check_site(sid, s, hosts_idx, net, today)
    for v in get(net, "gov.voters") or []:
        s = sites.get(v.get("site"))
        if not s:
            e(f"network.yaml: gov voter site {v.get('site')} does not exist")
        elif not get(s, f"onchain.accounts.{v.get('account')}"):
            e(f"network.yaml: gov voter {v.get('site')}.{v.get('account')} is not in onchain.accounts")
    pub = net.get("public_node_site")
    if pub and (pub not in sites or sites[pub].get("kind") != "public-node"):
        e(f"network.yaml: public_node_site {pub} is not a public-node site")

    for m in warnings:
        print(f"WARN  {m}")
    for m in errors:
        print(f"ERROR {m}")
    print(f"inventory: {len(sites)} sites, {len(errors)} errors, {len(warnings)} warnings ({INV})")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
