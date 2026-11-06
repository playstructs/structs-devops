#!/usr/bin/env python3
"""Lint the agent layer: skills, AGENTS.md budgets, links, the intent router.

  lint.py            print findings; exit 1 on errors
  lint.py --index    print "name<TAB>description" for every skill (used by bundle)
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("DEVOPS_ROOT") or Path(__file__).resolve().parents[2])
SKILLS = ROOT / ".agents" / "skills"
ROOT_BUDGET = 12 * 1024
CODEX_CAP = 32 * 1024
MAX_BODY_LINES = 500
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HARNESS_TOOLS = re.compile(
    r"\b(StrReplace|TodoWrite|CallMcpTool|ReadLints|run_terminal_cmd|apply_patch|SemanticSearch|"
    r"(Bash|Shell|Read|Write|Edit|Grep|Glob|Task|WebFetch) tool)\b"
)
ALLOWED_KEYS = {"name", "description", "disable-model-invocation"}
SKIP_DIRS = {".references", "state", "local", "dist", "node_modules", ".git"}

errors: list[str] = []
warnings: list[str] = []


def frontmatter(text: str):
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, text
    meta = {}
    for line in text[4:end].splitlines():
        if not line.strip():
            continue
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip().strip('"').strip("'")
    return meta, text[end + 5:]


def check_links(path: Path, text: str):
    for m in LINK_RE.finditer(text):
        target = m.group(1)
        if re.match(r"^(https?:|mailto:|#)", target):
            continue
        target = target.split("#", 1)[0]
        if not target:
            continue
        if not (path.parent / target).exists():
            errors.append(f"{path.relative_to(ROOT)}: broken link {m.group(1)}")


def skills():
    out = []
    for d in sorted(p for p in SKILLS.iterdir() if p.is_dir()) if SKILLS.is_dir() else []:
        f = d / "SKILL.md"
        if not f.is_file():
            errors.append(f"{d.relative_to(ROOT)}: missing SKILL.md")
            continue
        text = f.read_text()
        meta, body = frontmatter(text)
        rel = f.relative_to(ROOT)
        if meta is None:
            errors.append(f"{rel}: missing frontmatter")
            continue
        out.append((d.name, meta, body, f, text))
    return out


def lint():
    names = set()
    for name, meta, body, f, text in skills():
        rel = f.relative_to(ROOT)
        names.add(name)
        if meta.get("name") != name:
            errors.append(f"{rel}: name '{meta.get('name')}' must equal the folder name '{name}'")
        if len(name) > 64 or not NAME_RE.match(name):
            errors.append(f"{rel}: name must be lowercase-hyphenated and <= 64 characters")
        desc = meta.get("description", "")
        if not desc:
            errors.append(f"{rel}: missing description")
        elif len(desc) > 1024:
            errors.append(f"{rel}: description is {len(desc)} characters (max 1024)")
        elif "Use when" not in desc:
            errors.append(f"{rel}: description needs a 'Use when' clause")
        for k in meta:
            if k not in ALLOWED_KEYS:
                errors.append(f"{rel}: non-portable frontmatter key '{k}'")
        n = len(body.splitlines())
        if n > MAX_BODY_LINES:
            errors.append(f"{rel}: body is {n} lines (max {MAX_BODY_LINES})")
        for i, line in enumerate(text.splitlines(), 1):
            if HARNESS_TOOLS.search(line):
                errors.append(f"{rel}:{i}: names a harness-specific tool; describe the action as a command")
        check_links(f, text)

    agents_files = [p for p in ROOT.rglob("AGENTS.md")
                    if not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)
                    and p.relative_to(ROOT).parts[0] not in ("templates", "examples")]
    inv = (ROOT / os.environ.get("DEVOPS_INVENTORY", "inventory")).resolve()
    if inv.is_dir() and ROOT.resolve() not in inv.parents:
        agents_files += [p for p in inv.rglob("AGENTS.md") if not SKIP_DIRS.intersection(p.relative_to(inv).parts)]
    root_agents = ROOT / "AGENTS.md"
    if not root_agents.is_file():
        errors.append("AGENTS.md missing at the workspace root")
    else:
        size = root_agents.stat().st_size
        if size > ROOT_BUDGET:
            errors.append(f"AGENTS.md is {size} bytes (budget {ROOT_BUDGET})")
        text = root_agents.read_text()
        check_links(root_agents, text)
        sect = re.search(r"^## Intent → skill\n(.*?)(?=^## )", text, re.S | re.M)
        if not sect:
            errors.append("AGENTS.md: missing '## Intent → skill' router section")
        else:
            for ref in re.findall(r"`(structs-[a-z0-9-]+)`", sect.group(1)):
                if ref not in names:
                    errors.append(f"AGENTS.md router names `{ref}` but .agents/skills/{ref}/ does not exist")
    total = sum(p.stat().st_size for p in agents_files)
    if total > CODEX_CAP:
        errors.append(f"AGENTS.md files total {total} bytes (Codex reads at most {CODEX_CAP})")
    for p in agents_files:
        if p != root_agents:
            check_links(p, p.read_text())

    for m in warnings:
        print(f"WARN  {m}")
    for m in errors:
        print(f"ERROR {m}")
    print(f"agents lint: {len(names)} skills, {len(agents_files)} AGENTS.md ({total} bytes), "
          f"{len(errors)} errors, {len(warnings)} warnings")
    return 1 if errors else 0


def index():
    for name, meta, _body, _f, _t in skills():
        flag = " [workflow]" if meta.get("disable-model-invocation", "").lower() == "true" else ""
        print(f"{name}{flag}\t{meta.get('description', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(index() if "--index" in sys.argv[1:] else lint())
