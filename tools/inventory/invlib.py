"""Load the inventory through `yq -o=json` (no PyYAML needed on the hub)."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(os.environ.get("DEVOPS_ROOT", Path(__file__).resolve().parents[2]))
INV = Path(os.environ.get("DEVOPS_INVENTORY", ROOT / "inventory"))


def load_yaml(path: Path):
    out = subprocess.run(["yq", "-o=json", ".", str(path)], check=True,
                         capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else {}


def merge(base, over):
    """Maps merge recursively; anything else (lists included) is replaced."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merge(base.get(k), v) if k in base else v
        return out
    return over


def preset_file(name: str) -> Path:
    return ROOT / "networks" / f"{name}.yaml"


def load_network():
    net = load_yaml(INV / "network.yaml")
    preset = net.get("preset")
    if preset:
        pf = preset_file(preset)
        if not pf.is_file():
            raise SystemExit(f"network.yaml names preset {preset} but networks/{preset}.yaml does not exist")
        net = merge(load_yaml(pf), {k: v for k, v in net.items() if k != "preset"})
    return net


def load_inventory():
    network = load_network()
    sites = {}
    sdir = INV / "sites"
    if sdir.is_dir():
        for d in sorted(p for p in sdir.iterdir() if (p / "site.yaml").is_file()):
            sites[d.name] = load_yaml(d / "site.yaml")
    return network, sites


def site_dir(site_id: str) -> Path:
    return INV / "sites" / site_id


def host_index(sites: dict) -> dict:
    """host id -> (site id, host dict)"""
    idx = {}
    for sid, s in sites.items():
        for h in s.get("hosts") or []:
            idx.setdefault(h.get("id"), []).append((sid, h))
    return idx


def get(d, path, default=None):
    cur = d
    for part in path.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    return cur


def replace_block(text: str, name: str, body: str) -> str:
    begin = f"<!-- BEGIN GENERATED: {name} -->"
    end = f"<!-- END GENERATED: {name} -->"
    block = f"{begin}\n{body.rstrip()}\n{end}"
    if begin in text and end in text:
        pre = text.split(begin, 1)[0]
        post = text.split(end, 1)[1]
        return pre + block + post
    return text.rstrip() + "\n\n" + block + "\n"
