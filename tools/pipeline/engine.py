#!/usr/bin/env python3
"""Dev pipelines: carry an upstream change through the repos that consume it.

Called by tools/pipeline/pipeline.sh (`devops pipeline ...`); the format is in
docs/pipelines.md; pipeline files live in $DEVOPS_PIPELINES (inventory/pipelines/). Everything here is hub-local: clones live in
local/pipelines/repos/, run state in state/pipelines/runs/<run>/. Pushing and
deploying happen only through `devops pipeline publish`, which gates them.

  engine.py list | validate [file...] | status [pipeline] [--deployed]
  engine.py run <pipeline> [--stage S]... [--sha SHA] [--continue] [--force] [--fresh] [--no-agent]
  engine.py show [run] [stage] [--diff|--check|--prompt|--agent|--log|--verify]
  engine.py publish-plan <run> <stage> [--site S]   JSON plan for pipeline.sh to gate
  engine.py publish-exec <run> <stage>              push exactly what was planned
  engine.py deploy-record <run> <stage> <site>      verify and record a deploy
  engine.py watch                                   trigger refs that moved
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("DEVOPS_ROOT") or Path(__file__).resolve().parents[2])
INVENTORY = Path(os.environ.get("DEVOPS_INVENTORY") or ROOT / "inventory")
PIPELINES = Path(os.environ.get("DEVOPS_PIPELINES") or INVENTORY / "pipelines")
STATE = Path(os.environ.get("DEVOPS_STATE") or ROOT / "state") / "pipelines"
WORK = Path(os.environ.get("DEVOPS_LOCAL") or ROOT / "local") / "pipelines" / "repos"
REPORTS = Path(os.environ.get("DEVOPS_REPORTS") or INVENTORY / "reports")
REFS_TSV = Path(os.environ.get("DEVOPS_REFS") or ROOT / ".references") / "repos.tsv"
SKILLS = ROOT / ".agents" / "skills"
SHIMS = Path(__file__).resolve().parent / "shims"
DEVOPS = ROOT / "bin" / "devops"
NO_PUSH = "no-push://use-devops-pipeline-publish"
BUILTIN_CHECKS = ("sed-anchors", "merge-clean")
DONE = ("published", "up_to_date")
NPM_QUIET = {"npm_config_fund": "false", "npm_config_audit": "false", "npm_config_update_notifier": "false"}


class Fail(Exception):
    pass


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tail(text: str, n: int = 40) -> str:
    lines = (text or "").rstrip().splitlines()
    return "\n".join(lines[-n:])


def sh(cmd, cwd=None, check=True, env=None, timeout=None, logf: Path | None = None, input_text=None):
    argv = ["bash", "-c", cmd] if isinstance(cmd, str) else [str(c) for c in cmd]
    shown = cmd if isinstance(cmd, str) else shlex.join(argv)
    e = os.environ.copy()
    e.update(env or {})
    started = time.time()
    try:
        p = subprocess.run(argv, cwd=cwd, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           timeout=timeout, input=input_text,
                           stdin=None if input_text is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired as t:
        out = t.output.decode(errors="replace") if isinstance(t.output, bytes) else (t.output or "")
        if logf:
            with open(logf, "a") as fh:
                fh.write(f"$ {shown}\n{out}\n[timed out after {timeout}s]\n\n")
        raise Fail(f"timed out after {timeout}s: {shown}")
    if logf:
        with open(logf, "a") as fh:
            fh.write(f"$ {shown}   (cwd {cwd or '.'}, exit {p.returncode}, {time.time() - started:.0f}s)\n{p.stdout}\n")
    if check and p.returncode != 0:
        raise Fail(f"exit {p.returncode}: {shown}\n{tail(p.stdout, 25)}")
    return p


def git(d: Path, *args, check=True, logf=None) -> str:
    return sh(["git", "-C", str(d)] + list(args), check=check, logf=logf).stdout.strip()


def yaml_load(path: Path):
    p = sh(["yq", "-o=json", "-I=0", ".", str(path)])
    return json.loads(p.stdout or "null")


def fmt(template: str, values: dict) -> str:
    class Keep(dict):
        def __missing__(self, k):
            return "{" + k + "}"
    return template.format_map(Keep(values))


# --- repos, pipelines, inventory -------------------------------------------

def repo_table() -> dict:
    out = {}
    if REFS_TSV.is_file():
        for line in REFS_TSV.read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) >= 3:
                out[cols[0]] = {"url": cols[1], "ref": cols[2]}
    return out


def repo_url(name: str, override: str | None = None) -> str:
    if override:
        return override
    t = repo_table()
    if name not in t:
        raise Fail(f"repo {name} is not in {REFS_TSV.relative_to(ROOT)} (add it, or set url: on the stage)")
    return t[name]["url"]


def pipeline_files():
    return sorted(PIPELINES.glob("*.yaml")) if PIPELINES.is_dir() else []


def load_pipeline(pid: str) -> dict:
    f = PIPELINES / f"{pid}.yaml"
    if not f.is_file():
        names = ", ".join(p.stem for p in pipeline_files()) or "none"
        raise Fail(f"no pipeline {pid} (have: {names})")
    p = yaml_load(f)
    problems = validate_pipeline(p, f)
    if problems:
        raise Fail(f"{f.relative_to(ROOT)} is invalid:\n  " + "\n  ".join(problems))
    return p


def stage_kind(st: dict) -> str:
    if "deploy" in st:
        return "deploy"
    upd = st.get("update") or {}
    return "merge" if "merge" in upd else "submodule"


def check_items(st: dict):
    for c in st.get("check") or []:
        if isinstance(c, str):
            yield (c, {}) if c in BUILTIN_CHECKS else ("run", {"run": c})
        elif isinstance(c, dict) and len(c) == 1:
            k, v = next(iter(c.items()))
            yield (k, v if isinstance(v, dict) else {"run": v} if k == "run" else {})
        else:
            yield ("invalid", {"raw": c})


def check_commands(st: dict):
    """Commands an agent (or a person) can run in the clone to re-check."""
    for kind, cfg in check_items(st):
        if kind == "run":
            yield cfg["run"]
        elif kind == "sed-anchors":
            copies = " ".join(f"--copy {shlex.quote(f'{s}:{d}')}" for s, d in (cfg.get("copy") or {}).items())
            expects = " ".join(f"--expect {shlex.quote(f)}" for f in cfg.get("expect_files") or [])
            yield (f"python3 {shlex.quote(str(Path(__file__).resolve()))} check-anchors . {shlex.quote(cfg.get('script', ''))} "
                   f"--require {cfg.get('require', 'all')} {copies} {expects}").rstrip()
        else:
            yield "git diff --name-only --diff-filter=U   (must print nothing)"
            yield "git diff --check HEAD   (must report no leftover conflict markers)"


def validate_pipeline(p, f: Path):
    errs = []
    if not isinstance(p, dict):
        return ["not a mapping"]
    if p.get("schema") != "structs-devops/pipeline/v1":
        errs.append("schema must be structs-devops/pipeline/v1")
    if p.get("id") != f.stem:
        errs.append(f"id must equal the file name ({f.stem})")
    trig = p.get("trigger") or {}
    if not trig.get("repo") or not trig.get("ref"):
        errs.append("trigger needs repo and ref")
    elif not trig.get("url") and trig["repo"] not in repo_table():
        errs.append(f"trigger repo {trig['repo']} is not in .references/repos.tsv")
    if trig.get("on_change", "notify") not in ("notify", "prepare"):
        errs.append("trigger.on_change must be notify or prepare")
    stages = p.get("stages") or []
    if not stages:
        errs.append("no stages")
    seen = []
    for st in stages:
        sid = st.get("id") or "?"
        where = f"stage {sid}"
        if not st.get("id") or not re.match(r"^[a-z0-9][a-z0-9-]*$", st["id"]):
            errs.append(f"{where}: id must be lowercase-hyphenated")
        if sid in seen:
            errs.append(f"{where}: duplicate id")
        for n in st.get("needs") or []:
            if n not in seen:
                errs.append(f"{where}: needs {n}, which is not an earlier stage")
        seen.append(sid)
        kind = stage_kind(st)
        if kind == "deploy":
            dep = st.get("deploy") or {}
            for k in ("repo", "ref", "procedure"):
                if not dep.get(k):
                    errs.append(f"{where}: deploy needs {k}")
            continue
        if st.get("needs"):
            errs.append(f"{where}: needs is only supported on deploy stages")
        if not st.get("repo") or not st.get("branch"):
            errs.append(f"{where}: needs repo and branch")
        elif not st.get("url") and st["repo"] not in repo_table():
            errs.append(f"{where}: repo {st['repo']} is not in .references/repos.tsv")
        upd = st.get("update") or {}
        if len([k for k in ("submodule", "merge") if k in upd]) != 1:
            errs.append(f"{where}: update needs exactly one of submodule, merge")
        for kind_, cfg in check_items(st):
            if kind_ == "invalid":
                errs.append(f"{where}: check entries are a command string, run: <cmd>, sed-anchors: {{...}} or merge-clean")
            elif kind_ == "sed-anchors" and not cfg.get("script"):
                errs.append(f"{where}: sed-anchors needs script")
            elif kind_ == "sed-anchors" and cfg.get("require", "all") not in ("all", "script"):
                errs.append(f"{where}: sed-anchors require must be all or script")
            elif kind_ not in ("run",) + BUILTIN_CHECKS:
                errs.append(f"{where}: unknown check {kind_}")
        fix = st.get("fix")
        if fix:
            sk = fix.get("skill")
            if not sk or not (SKILLS / sk / "SKILL.md").is_file():
                errs.append(f"{where}: fix.skill {sk} not found in .agents/skills/")
            if not isinstance(fix.get("attempts", 2), int) or not 0 <= fix.get("attempts", 2) <= 5:
                errs.append(f"{where}: fix.attempts must be 0..5")
        pub = st.get("publish") or {}
        if pub.get("tag") not in (None, "next-patch"):
            errs.append(f"{where}: publish.tag supports next-patch only")
        if pub.get("tier", 2) not in (2, 3):
            errs.append(f"{where}: publish.tier must be 2 or 3")
        if st.get("gate", "approve") != "approve":
            errs.append(f"{where}: gate must be approve (publishing always needs an approval)")
    return errs


def sites_tracking(repo: str, ref: str):
    out = []
    for f in sorted((INVENTORY / "sites").glob("*/site.yaml")):
        site = f.parent.name
        doc = yaml_load(f) or {}
        for src in doc.get("sources") or []:
            if src.get("repo") == repo and src.get("ref") == ref and src.get("host") and src.get("path"):
                out.append({"site": site, "host": src["host"], "path": src["path"]})
    return out


def deployed_sha(site: str, host: str, path: str):
    q = shlex.quote(path)
    cmd = f"git -c safe.directory={q} -C {q} rev-parse HEAD"
    p = sh([str(DEVOPS), "ssh", f"{site}:{host}", "--", cmd], check=False, env={"DEVOPS_NO_NOTIFY": "1"}, timeout=60)
    m = re.search(r"\b[0-9a-f]{40}\b", p.stdout or "")
    return m.group(0) if (p.returncode == 0 and m) else None


# --- clones ----------------------------------------------------------------

def ensure_clone(repo: str, url: str, logf=None) -> Path:
    d = WORK / repo
    if not (d / ".git").exists():
        d.parent.mkdir(parents=True, exist_ok=True)
        say(f"  clone {repo}")
        sh(["git", "clone", "--quiet", "--filter=blob:none", url, str(d)], logf=logf, timeout=1200)
    if git(d, "remote", "get-url", "--push", "origin", check=False) != NO_PUSH:
        git(d, "remote", "set-url", "--push", "origin", NO_PUSH)
    if git(d, "config", "--local", "rerere.enabled", check=False) != "true":
        git(d, "config", "--local", "rerere.enabled", "true")
        git(d, "config", "--local", "rerere.autoUpdate", "true")
    return d


def ls_remote(url: str, ref: str) -> str:
    p = sh(["git", "ls-remote", url, f"refs/heads/{ref}"], timeout=60)
    sha = (p.stdout.split() or [""])[0]
    if not re.match(r"^[0-9a-f]{40}$", sha):
        raise Fail(f"cannot resolve {ref} at {url}")
    return sha


def remote_tags(url: str):
    p = sh(["git", "ls-remote", "--tags", "--refs", url, "v*"], timeout=60)
    tags = []
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            name = parts[1].rsplit("/", 1)[-1]
            m = re.match(r"^v(\d+)\.(\d+)\.(\d+)$", name)
            if m:
                tags.append(((int(m[1]), int(m[2]), int(m[3])), name, parts[0]))
    return sorted(tags)


def next_patch_tag(url: str):
    tags = remote_tags(url)
    if not tags:
        return "v0.0.1", None
    (a, b, c), name, _ = tags[-1]
    return f"v{a}.{b}.{c + 1}", name


def pin_of(d: Path, rev: str, path: str):
    out = git(d, "ls-tree", rev, path, check=False)
    parts = out.split()
    return parts[2] if len(parts) >= 3 and parts[1] == "commit" else None


def is_ancestor(d: Path, a: str, b: str) -> bool:
    return sh(["git", "-C", str(d), "merge-base", "--is-ancestor", a, b], check=False).returncode == 0


def prs_in(log_text: str) -> str:
    nums = re.findall(r"Merge pull request #(\d+)", log_text or "")
    return ", ".join(f"#{n}" for n in nums)


# --- runs ------------------------------------------------------------------

def run_path(run_id: str) -> Path:
    return STATE / "runs" / run_id


def load_run(run_id: str | None) -> dict:
    if not run_id or run_id == "latest":
        runs = sorted((STATE / "runs").glob("*/run.json"), key=lambda p: p.stat().st_mtime) if (STATE / "runs").is_dir() else []
        if not runs:
            raise Fail("no pipeline runs yet (devops pipeline run <pipeline>)")
        f = runs[-1]
    else:
        f = run_path(run_id) / "run.json"
        if not f.is_file():
            pf = STATE / f"{run_id}.latest"
            if pf.is_file():
                f = run_path(pf.read_text().strip()) / "run.json"
            if not f.is_file():
                raise Fail(f"no run {run_id} (devops pipeline show lists the latest)")
    return json.loads(f.read_text())


def save_run(run: dict) -> None:
    d = run_path(run["id"])
    d.mkdir(parents=True, exist_ok=True)
    run["updated"] = now_iso()
    write_report(run)
    tmp = d / "run.json.tmp"
    tmp.write_text(json.dumps(run, indent=2) + "\n")
    tmp.replace(d / "run.json")
    (STATE / f"{run['pipeline']}.latest").write_text(run["id"] + "\n")


def stage_dir(run: dict, sid: str) -> Path:
    d = run_path(run["id"]) / sid
    d.mkdir(parents=True, exist_ok=True)
    return d


def rel(p) -> str:
    try:
        return str(Path(p).relative_to(ROOT))
    except ValueError:
        return str(p)


def next_step(run: dict, sid: str) -> str:
    S = run["stages"][sid]
    st = S.get("status")
    if st == "ready":
        if S.get("kind") == "deploy":
            pend = [s for s, v in (S.get("sites") or {}).items() if v.get("status") != "deployed" and v.get("status") != "up_to_date"]
            return f"devops pipeline publish {run['id']} {sid}" + (f" --site {pend[0]}" if pend else "")
        return f"devops pipeline show {run['id']} {sid} --diff; then devops pipeline publish {run['id']} {sid}"
    if st == "needs_fix":
        return f"fix in {rel(WORK / S['repo'])} (prompt: {rel(stage_dir(run, sid) / 'prompt.md')}), then devops pipeline run {run['pipeline']} --stage {sid} --continue"
    if st == "failed":
        return f"devops pipeline show {run['id']} {sid} --log; fix the cause, then devops pipeline run {run['pipeline']} --stage {sid}"
    if st == "waiting":
        return S.get("note", "")
    return ""


def write_report(run: dict) -> None:
    created = dt.datetime.strptime(run.get("created") or now_iso(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    day = created.astimezone().strftime("%Y-%m-%d")
    d = REPORTS / "runs" / day
    d.mkdir(parents=True, exist_ok=True)
    t = run["trigger"]
    lines = [f"# pipeline {run['pipeline']}: run {run['id']}", "",
             f"Trigger: {t['repo']}@{t['ref']} `{t['sha'][:8]}`. Created {run.get('created')}, updated {run.get('updated')}.", "",
             "| stage | target | status | detail |", "|---|---|---|---|"]
    for sid in run["order"]:
        S = run["stages"][sid]
        target = f"{S.get('repo', '')}@{S.get('branch', '')}" if S.get("kind") != "deploy" else ", ".join(S.get("sites") or {}) or "-"
        detail = S.get("note") or ((S.get("error") or "").splitlines() or [""])[0]
        if S.get("commit"):
            detail = f"commit `{S['commit'][:8]}`" + (f", tag {S['tag']}" if S.get("tag") else "") + (f"; {detail}" if detail else "")
        lines.append(f"| {sid} | {target} | {S.get('status', 'pending')} | {detail.replace('|', '/')} |")
    for sid in run["order"]:
        S = run["stages"][sid]
        lines += ["", f"## {sid}: {S.get('status', 'pending')}", ""]
        if S.get("upstream_log"):
            lines += ["Upstream commits:", "```", tail(S["upstream_log"], 40), "```"]
        if S.get("files"):
            lines += ["Change:", "```", tail(S["files"], 40), "```"]
        if S.get("checks"):
            lines += [f"Checks: {S['checks']}"]
        lines += [f"Warning: {w}" for w in S.get("warnings") or []]
        if S.get("agent"):
            a = S["agent"]
            lines += [f"Agent: {a.get('runner')} x{a.get('attempts')} ({a.get('result')})"]
        if S.get("sites"):
            for s, v in S["sites"].items():
                lines.append(f"- {s}:{v.get('host')} deployed `{(v.get('deployed') or '?')[:8]}` -> {v.get('status')}")
        if S.get("error"):
            lines += ["Error:", "```", tail(S["error"], 30), "```"]
        n = next_step(run, sid)
        if n:
            lines += ["", f"Next: `{n}`" if "\n" not in n else n]
    (d / f"pipeline-{run['id']}.md").write_text("\n".join(lines) + "\n")
    run["report"] = rel(d / f"pipeline-{run['id']}.md")


# --- checks ----------------------------------------------------------------

def check_sed_anchors(cfg: dict, d: Path, logf: Path):
    script = cfg["script"]
    if not (d / script).is_file():
        return False, f"script {script} not found"
    tmp = Path(tempfile.mkdtemp(prefix="devops-anchors-"))
    try:
        for src, dst in (cfg.get("copy") or {}).items():
            s = d / src
            if s.is_dir():
                shutil.copytree(s, tmp / dst, symlinks=True)
            elif s.is_file():
                (tmp / dst).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(s, tmp / dst)
            else:
                return False, f"copy source {src} not found (is the submodule checked out?)"
        real = shutil.which("sed") or "/usr/bin/sed"
        logp = tmp / ".sed-shim.jsonl"
        env = {"PATH": f"{SHIMS}:{os.environ.get('PATH', '')}", "SED_SHIM_REAL": real, "SED_SHIM_LOG": str(logp)}
        p = sh(["bash", script, str(tmp)] + [str(a) for a in cfg.get("args") or []], cwd=d, check=False, env=env,
               logf=logf, timeout=600)
        rows = [json.loads(x) for x in logp.read_text().splitlines()] if logp.exists() else []
        # require: all     every substitution must change its file (scripts without their own guards)
        # require: script  the script's exit code and expect_files decide; misses are reported only
        strict = cfg.get("require", "all") == "all"
        out, bad = [], 0
        for r in rows:
            f = r["file"].replace(str(tmp) + "/", "")
            state = "ok" if r["changed"] else ("NO FILE" if r.get("missing") else "NO MATCH")
            if state != "ok" and (strict or r.get("missing")):
                bad += 1
            elif state != "ok":
                state = "no match"
            expr = " ".join(r["expr"].split())
            out.append(f"{state:9} {f}  {expr[:150]}")
        touched = {r["file"].replace(str(tmp) + "/", "") for r in rows}
        for f in cfg.get("expect_files") or []:
            if f not in touched:
                bad += 1
                out.append(f"NOT RUN   {f}  (expected the script to edit it; it was skipped or moved)")
        if p.returncode != 0:
            bad += 1
            out.append(f"script exited {p.returncode}:\n{tail(p.stdout, 15)}")
        if not rows:
            bad += 1
            out.append("no in-place sed edits were recorded")
        misses = sum(1 for r in rows if not r["changed"])
        out.append(f"{len(rows)} substitution(s), {misses} without a match, {bad} problem(s)"
                   + ("" if strict else " (require: script; lowercase 'no match' rows are alternatives the script allows)"))
        return bad == 0, "\n".join(out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_merge_clean(d: Path):
    unmerged = git(d, "diff", "--name-only", "--diff-filter=U", check=False).split()
    changed = set(git(d, "diff", "--name-only", "HEAD", check=False).split()) | set(unmerged)
    markers = []
    for f in sorted(changed):
        fp = d / f
        if fp.is_file():
            try:
                for n, line in enumerate(fp.read_text(errors="replace").splitlines(), 1):
                    if re.match(r"^(<{7}|>{7})( |$)|^={7}$", line):
                        markers.append(f"{f}:{n}: {line[:40]}")
            except OSError:
                pass
    out = []
    if unmerged:
        out.append("unmerged: " + " ".join(unmerged))
    if markers:
        out.append("conflict markers:\n" + "\n".join(markers[:60]))
    return not unmerged and not markers, "\n".join(out) or "clean"


def run_checks(st: dict, d: Path, sdir: Path, logf: Path, attempt: int):
    parts, ok = [], True
    for kind, cfg in check_items(st):
        if kind == "run":
            p = sh(cfg["run"], cwd=d, check=False, env=NPM_QUIET, logf=logf, timeout=int(cfg.get("timeout", 900)))
            passed, text, name = p.returncode == 0, tail(p.stdout, 150), cfg["run"]
        elif kind == "sed-anchors":
            passed, text = check_sed_anchors(cfg, d, logf)
            name = f"sed-anchors {cfg['script']}"
        else:
            passed, text = check_merge_clean(d)
            name = "merge-clean"
        say(f"  check {name}: {'PASS' if passed else 'FAIL'}")
        parts.append(f"### {name}: {'PASS' if passed else 'FAIL'}\n```\n{text}\n```")
        ok = ok and passed
    report = "\n\n".join(parts) or "(no checks declared)"
    (sdir / f"check-{attempt}.md").write_text(report + "\n")
    (sdir / "check.md").write_text(report + "\n")
    return ok, report


# --- agent -----------------------------------------------------------------

RUNNER_BIN = {"cursor": "cursor-agent", "claude": "claude", "codex": "codex"}


def pick_runner():
    if os.environ.get("DEVOPS_AGENT_CMD"):
        return "custom"
    want = os.environ.get("DEVOPS_AGENT_CLI", "auto")
    if want == "none":
        return None
    order = ["cursor", "claude", "codex"] if want == "auto" else [want]
    for name in order:
        if name in RUNNER_BIN and shutil.which(RUNNER_BIN[name]):
            return name
    return None


def runner_argv(runner: str, prompt: str, prompt_file: Path, d: Path):
    """(argv or shell string, stdin text). Override with DEVOPS_AGENT_CMD."""
    if runner == "custom":
        cmd = os.environ["DEVOPS_AGENT_CMD"].replace("{prompt_file}", shlex.quote(str(prompt_file))).replace("{workdir}", shlex.quote(str(d)))
        return cmd, None
    if runner == "cursor":
        return ["cursor-agent", "-p", "--force", "--output-format", "text", prompt], None
    if runner == "claude":
        tools = ["Read", "Edit", "Write", "Glob", "Grep", "Bash(npm test:*)", "Bash(npm run:*)", "Bash(npm ci:*)",
                 "Bash(node:*)", "Bash(python3:*)", "Bash(bash scripts/:*)", "Bash(git diff:*)", "Bash(git status:*)",
                 "Bash(git log:*)", "Bash(git show:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(grep:*)", "Bash(rg:*)"]
        return ["claude", "-p", "--permission-mode", "acceptEdits", "--allowedTools"] + tools, prompt
    return ["codex", "exec", "--full-auto", "-C", str(d), "-"], prompt


def write_prompt(run: dict, st: dict, S: dict, d: Path, report: str, attempt: int) -> Path:
    fix = st.get("fix") or {}
    skill = (SKILLS / fix["skill"] / "SKILL.md").read_text() if fix.get("skill") else ""
    if skill.startswith("---\n"):
        skill = skill[skill.find("\n---\n", 4) + 5:]
    sub = (st.get("update") or {}).get("submodule")
    t = run["trigger"]
    args = "\n".join(f"- {k}: {v}" for k, v in (fix.get("args") or {}).items())
    checks = "\n".join(f"  - `{c}`" for c in check_commands(st))
    rules = [
        "Change files in this repository only." + (f" Never edit inside `{sub}/`: it is upstream code pinned by the pipeline." if sub else ""),
        "Do not commit, push, tag, rebase, reset, or change git config or remotes. The pipeline commits your working-tree changes after the user reviews them.",
        "Do not run devops commands, deploy anything, or reach servers.",
        "Re-run the checks until they pass:\n" + checks,
        "Finish with a short summary: each file you changed and why, and anything you were unsure about.",
    ]
    text = "\n".join([
        f"# Pipeline fix: {run['pipeline']} / {st['id']} (attempt {attempt})", "",
        f"You are in a working copy of **{st['repo']}** on branch `{st['branch']}` at `{d}`.",
        (f"The pipeline merged upstream {t['repo']} `{t['sha'][:8]}` ({t['ref']}) into `{st['branch']}` and the checks below failed. "
         if stage_kind(st) == "merge" else
         f"The pipeline moved it to upstream {t['repo']} `{t['sha'][:8]}` ({t['ref']}) and the checks below failed. ")
        + "Fix this repository so they pass.", "",
        "## Rules", "", *[f"- {r}" for r in rules], "",
        *(["## Parameters", "", args, ""] if args else []),
        "## Upstream commits", "", "```", tail(S.get("upstream_log", ""), 60) or "(none recorded)", "```", "",
        "## Upstream files changed", "", "```", tail(S.get("upstream_stat", ""), 80) or "(none recorded)", "```", "",
        *(["## Merge conflicts", "", "\n".join(f"- `{c}`" for c in S["conflicts"]), ""] if S.get("conflicts") else []),
        "## Failed checks", "", report, "",
        f"## Instructions ({fix.get('skill', 'none')})", "", skill.strip(), "",
    ])
    f = stage_dir(run, st["id"]) / "prompt.md"
    f.write_text(text)
    return f


def run_agent(run: dict, st: dict, S: dict, d: Path, report: str, attempt: int, runner: str):
    sdir = stage_dir(run, st["id"])
    pf = write_prompt(run, st, S, d, report, attempt)
    head = git(d, "rev-parse", "HEAD")
    say(f"  agent ({runner}) attempt {attempt}")
    argv, stdin_text = runner_argv(runner, pf.read_text(), pf, d)
    p = sh(argv, cwd=d, check=False, env={"DEVOPS_AGENT": "1", "GIT_TERMINAL_PROMPT": "0", **NPM_QUIET},
           timeout=int(os.environ.get("DEVOPS_AGENT_TIMEOUT", "1800")), input_text=stdin_text)
    (sdir / f"agent-{attempt}.log").write_text(p.stdout or "")
    if git(d, "remote", "get-url", "--push", "origin", check=False) != NO_PUSH:
        git(d, "remote", "set-url", "--push", "origin", NO_PUSH)
        S.setdefault("warnings", []).append("the agent changed the push URL; it was reset")
    new_head = git(d, "rev-parse", "HEAD")
    if new_head != head:
        if is_ancestor(d, head, new_head):
            git(d, "reset", "--soft", head)
            S.setdefault("warnings", []).append("the agent committed; its commits were folded back into the working tree")
        else:
            raise Fail(f"the agent moved HEAD off {head[:8]}; refusing to continue (inspect {d})")
    sub = (st.get("update") or {}).get("submodule")
    if sub:
        sd = d / sub
        if git(sd, "status", "--porcelain", check=False) or git(sd, "rev-parse", "HEAD", check=False) != run["trigger"]["sha"]:
            raise Fail(f"the agent changed the upstream submodule {sub}/; overlay repos must not edit upstream (inspect {d})")
    stage_resolved(S, d)
    (sdir / f"agent-{attempt}.diff").write_text(git(d, "diff", "HEAD", check=False) + "\n")
    return p.returncode


def stage_resolved(S: dict, d: Path) -> None:
    unmerged = set(git(d, "diff", "--name-only", "--diff-filter=U", check=False).split())
    for c in S.get("conflicts") or []:
        if c in unmerged and check_merge_clean_file(d, c)[0]:
            git(d, "add", "--", c, check=False)


def check_merge_clean_file(d: Path, f: str):
    fp = d / f
    if not fp.exists():
        return True, ""
    try:
        text = fp.read_text(errors="replace")
    except OSError:
        return False, ""
    return not re.search(r"^(<{7}|>{7})( |$)|^={7}$", text, re.M), ""


# --- stages ----------------------------------------------------------------

def reset_clone(d: Path, branch: str, logf: Path) -> str:
    """Throw away anything left from an earlier run; ignored files (node_modules) stay."""
    if (d / ".git" / "MERGE_HEAD").exists():
        git(d, "merge", "--abort", check=False, logf=logf)
    git(d, "fetch", "--quiet", "--prune", "origin", logf=logf)
    git(d, "reset", "--quiet", "--hard", check=False, logf=logf)
    git(d, "clean", "-fdq", logf=logf)
    git(d, "checkout", "--quiet", "-B", branch, f"origin/{branch}", logf=logf)
    git(d, "reset", "--quiet", "--hard", f"origin/{branch}", logf=logf)
    git(d, "submodule", "update", "--quiet", "--force", "--recursive", check=False, logf=logf)
    git(d, "submodule", "foreach", "--quiet", "--recursive", "git clean -fdq", check=False, logf=logf)
    return git(d, "rev-parse", "HEAD")


def already_current(run: dict, st: dict, d: Path, logf: Path):
    """Answer from origin/<branch> before touching the worktree or cloning submodules."""
    git(d, "fetch", "--quiet", "--prune", "origin", logf=logf)
    sha = run["trigger"]["sha"]
    ref = f"origin/{st['branch']}"
    if stage_kind(st) == "merge":
        if sh(["git", "-C", str(d), "cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0:
            git(d, "fetch", "--quiet", "origin", sha, logf=logf)
        return f"{st['branch']} already contains {sha[:8]}" if is_ancestor(d, sha, ref) else None
    return f"already at {sha[:8]}" if pin_of(d, ref, st["update"]["submodule"]) == sha else None


def update_submodule(run: dict, st: dict, S: dict, d: Path, logf: Path, force: bool) -> bool:
    path = st["update"]["submodule"]
    sha = run["trigger"]["sha"]
    git(d, "submodule", "sync", "--quiet", "--", path, logf=logf)
    init = ["git", "-C", str(d), "submodule", "update", "--init", "--quiet"]
    if not (d / ".git" / "modules" / path).exists():
        init.append("--filter=blob:none")
    sh(init + ["--", path], logf=logf, timeout=1800)
    old = pin_of(d, "HEAD", path)
    S["pin_before"] = old
    sub = d / path
    if old == sha and not force:
        return False
    if sh(["git", "-C", str(sub), "cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0:
        sh(["git", "-C", str(sub), "fetch", "--quiet", "origin", sha], logf=logf, timeout=900)
    git(sub, "checkout", "--quiet", "--detach", sha, logf=logf)
    git(d, "add", path)
    if old and old != sha:
        if sh(["git", "-C", str(sub), "cat-file", "-e", f"{old}^{{commit}}"], check=False).returncode != 0:
            sh(["git", "-C", str(sub), "fetch", "--quiet", "origin"], check=False, logf=logf, timeout=900)
        S["upstream_log"] = git(sub, "log", "--oneline", f"{old}..{sha}", check=False)
        S["upstream_stat"] = git(sub, "diff", "--stat=120", f"{old}..{sha}", check=False)
        if not S["upstream_log"] and is_ancestor(sub, sha, old):
            back = len(git(sub, "rev-list", f"{sha}..{old}", check=False).split())
            S.setdefault("warnings", []).append(f"moves {path} back {back} commit(s) from {old[:8]}")
    say(f"  submodule {path}: {(old or 'none')[:8]} -> {sha[:8]}")
    return True


def update_merge(run: dict, st: dict, S: dict, d: Path, logf: Path, force: bool) -> bool:
    frm = st["update"]["merge"]
    sha = run["trigger"]["sha"]
    if sh(["git", "-C", str(d), "cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0:
        git(d, "fetch", "--quiet", "origin", sha, logf=logf)
    if is_ancestor(d, sha, "HEAD") and not force:
        S["note"] = f"{st['branch']} already contains {sha[:8]}"
        return False
    S["upstream_log"] = git(d, "log", "--oneline", f"HEAD..{sha}", check=False)
    S["upstream_stat"] = git(d, "diff", "--stat=120", f"HEAD...{sha}", check=False)
    target = frm if git(d, "rev-parse", frm, check=False) == sha else sha
    p = sh(["git", "-C", str(d), "merge", "--no-ff", "--no-edit", target], check=False, logf=logf)
    unmerged = git(d, "diff", "--name-only", "--diff-filter=U", check=False).split()
    reused = re.findall(r"^(?:Resolved|Staged) '(.+)' using previous resolution", p.stdout or "", re.M)
    S["conflicts"] = unmerged + [f for f in reused if f not in unmerged]
    if p.returncode != 0 and not unmerged and not (d / ".git" / "MERGE_HEAD").exists():
        raise Fail(f"merge of {target} failed:\n{tail(p.stdout, 20)}")
    if reused:
        S.setdefault("warnings", []).append(
            f"reused the resolution from an earlier run (git rerere) for: {', '.join(reused)}; check it in the remerge diff")
    state = f"{len(unmerged)} conflict(s)" if unmerged else "clean"
    say(f"  merge {target} into {st['branch']}: {state}" + (f", {len(reused)} resolved from an earlier resolution" if reused else ""))
    return True


def commit_stage(run: dict, st: dict, S: dict, d: Path, logf: Path) -> bool:
    t = run["trigger"]
    merging = (d / ".git" / "MERGE_HEAD").exists()
    log_text = S.get("upstream_log", "")
    prs = prs_in(log_text)
    latest = next((ln.split(" ", 1)[-1] for ln in log_text.splitlines() if not ln.split(" ", 1)[-1].startswith("Merge ")), "")
    if prs:
        summ = f"PR {prs}"
    elif latest:
        summ = latest
    else:
        summ = f"back from {(S.get('pin_before') or '')[:7]}"
    values = {"upstream": t["repo"], "ref": t["ref"], "short": t["sha"][:7], "sha": t["sha"], "prs": prs,
              "summary": summ, "count": len(log_text.splitlines()), "branch": st["branch"]}
    prepared = git(d, "rev-parse", "HEAD") != S["base"]
    if merging:
        git(d, "add", "-A", logf=logf)
        git(d, "commit", "--quiet", "--no-edit", logf=logf)
    elif git(d, "status", "--porcelain"):
        git(d, "add", "-A", logf=logf)
        if prepared and stage_kind(st) == "submodule":
            git(d, "commit", "--quiet", "--amend", "--no-edit", logf=logf)
        elif prepared:
            git(d, "commit", "--quiet", "-m", fmt("Fix {branch} after merging {upstream} {short}", values), logf=logf)
        else:
            git(d, "commit", "--quiet", "-m", fmt(st.get("commit") or "Follow {upstream} {short}", values).strip(), logf=logf)
    head = git(d, "rev-parse", "HEAD")
    if head == S["base"]:
        return False
    S["commit"] = head
    S["subject"] = git(d, "log", "-1", "--format=%s")
    S["files"] = git(d, "diff", "--stat=120", f"{S['base']}..{head}")
    sdir = stage_dir(run, st["id"])
    if stage_kind(st) == "merge":
        diff = git(d, "show", "--remerge-diff", "--format=%H %s", head, check=False) if S.get("conflicts") else ""
        (sdir / "diff.patch").write_text((diff or f"clean merge; upstream diff: git -C {d} diff {S['base']}..{head}") + "\n")
    else:
        (sdir / "diff.patch").write_text(git(d, "diff", f"{S['base']}..{head}", "--submodule=log") + "\n")
    say(f"  commit {head[:8]} {S['subject']}")
    return True


def verify_stage(st: dict, S: dict, d: Path, sdir: Path) -> None:
    vlog = sdir / "verify.log"
    vlog.write_text("")
    try:
        for c in st.get("verify") or []:
            say(f"  verify {c}")
            p = sh(c, cwd=d, check=False, env=NPM_QUIET, logf=vlog, timeout=int(os.environ.get("DEVOPS_PIPELINE_VERIFY_TIMEOUT", "3600")))
            if p.returncode != 0:
                raise Fail(f"verify failed: {c} (exit {p.returncode})\n{tail(p.stdout, 25)}")
    finally:
        git(d, "reset", "--quiet", "--hard", "HEAD", check=False)
        git(d, "clean", "-fdq", check=False)
        git(d, "submodule", "update", "--quiet", "--recursive", check=False)
    if git(d, "rev-parse", "HEAD") != S["commit"]:
        raise Fail(f"verify moved HEAD in {d}; refusing")


def prepare_repo_stage(run: dict, st: dict, opts) -> None:
    sid = st["id"]
    S = run["stages"][sid]
    sdir = stage_dir(run, sid)
    logf = sdir / "log.txt"
    url = repo_url(st["repo"], st.get("url"))
    d = ensure_clone(st["repo"], url, logf)
    if not git(d, "config", "user.email", check=False):
        raise Fail("git user.email is not set; the pipeline commits as you (git config --global user.email ...)")
    kind = stage_kind(st)
    continuing = opts.cont and S.get("status") in ("needs_fix", "failed") and S.get("phase") in ("check", "verify") and S.get("base")
    if continuing:
        say(f"  continue in {rel(d)} (working tree kept)")
        with open(logf, "a") as fh:
            fh.write(f"\n--- continue {now_iso()}\n")
    else:
        logf.write_text(f"--- prepare {now_iso()}\n")
        for k in ("commit", "subject", "files", "tag", "conflicts", "upstream_log", "upstream_stat", "agent", "error", "note", "warnings", "checks"):
            S.pop(k, None)
        note = None if opts.force else already_current(run, st, d, logf)
        if note:
            S["base"] = git(d, "rev-parse", f"origin/{st['branch']}")
            S["status"], S["phase"], S["note"] = "up_to_date", "update", note
            say(f"  up to date ({note})")
            return
        S["base"] = reset_clone(d, st["branch"], logf)
        S["phase"] = "update"
        changed = (update_merge if kind == "merge" else update_submodule)(run, st, S, d, logf, opts.force)
        if not changed:
            S["status"] = "up_to_date"
            S.setdefault("note", f"already at {run['trigger']['sha'][:8]}")
            say(f"  up to date ({S['note']})")
            return
    S["phase"] = "check"
    if continuing:
        stage_resolved(S, d)
    for c in st.get("setup") or []:
        say(f"  setup {c}")
        sh(c, cwd=d, env=NPM_QUIET, logf=logf, timeout=1800)
    attempt = S.get("attempt", 0) + 1 if continuing else 1
    ok, report = run_checks(st, d, sdir, logf, attempt)
    fix = st.get("fix") or {}
    tries = 0
    runner = None if opts.no_agent else pick_runner()
    while not ok:
        if not fix or tries >= int(fix.get("attempts", 2)) or not runner:
            pf = write_prompt(run, st, S, d, report, attempt) if fix else None
            S["status"] = "needs_fix"
            S["attempt"] = attempt
            S["checks"] = "FAIL"
            if not fix:
                S["note"] = "checks failed and the stage has no fix skill"
            elif not runner:
                S["note"] = "no agent CLI (cursor-agent, claude, codex) or --no-agent: fix by hand or paste the prompt into any agent"
            else:
                S["note"] = f"still failing after {tries} agent attempt(s)"
            S["agent"] = {"runner": runner or "none", "attempts": tries, "result": "failed" if tries else "not run"}
            if pf:
                say(f"  needs fix: prompt {rel(pf)}")
            return
        tries += 1
        rc = run_agent(run, st, S, d, report, attempt, runner)
        attempt += 1
        ok, report = run_checks(st, d, sdir, logf, attempt)
        S["agent"] = {"runner": runner, "attempts": tries, "result": "passed" if ok else f"failed (exit {rc})"}
    S["checks"] = "PASS"
    S["attempt"] = attempt
    if not commit_stage(run, st, S, d, logf):
        S["status"] = "up_to_date"
        S["note"] = "nothing to commit"
        return
    S["phase"] = "verify"
    verify_stage(st, S, d, sdir)
    pub = st.get("publish") or {}
    if pub.get("tag") == "next-patch":
        S["tag"], S["tag_after"] = next_patch_tag(url)
    S["phase"] = "gate"
    S["status"] = "ready"


def prepare_deploy_stage(run: dict, st: dict, opts) -> None:
    S = run["stages"][st["id"]]
    for n in st.get("needs") or []:
        ns = run["stages"][n].get("status", "pending")
        if ns not in DONE:
            S["status"] = "waiting"
            S["note"] = f"waits for {n} ({ns})"
            say(f"  {S['note']}")
            return
    dep = st["deploy"]
    url = repo_url(dep["repo"], dep.get("url"))
    S["target"] = ls_remote(url, dep["ref"])
    S["procedure"] = dep["procedure"]
    sites = sites_tracking(dep["repo"], dep["ref"])
    if not sites:
        S["status"] = "up_to_date"
        S["note"] = f"no site in the inventory tracks {dep['repo']}@{dep['ref']}"
        return
    S["sites"] = {}
    for s in sites:
        cur = deployed_sha(s["site"], s["host"], s["path"])
        status = "up_to_date" if cur == S["target"] else "pending"
        S["sites"][s["site"]] = {**s, "deployed": cur, "status": status}
        say(f"  {s['site']}:{s['host']} at {(cur or 'unknown')[:8]}, branch head {S['target'][:8]} -> {status}")
    S["status"] = "up_to_date" if all(v["status"] == "up_to_date" for v in S["sites"].values()) else "ready"


# --- commands --------------------------------------------------------------

def cmd_list(_a) -> int:
    for f in pipeline_files():
        p = yaml_load(f) or {}
        t = p.get("trigger") or {}
        print(f"{f.stem:20} {t.get('repo')}@{t.get('ref')} -> {', '.join(s.get('id', '?') for s in p.get('stages') or [])}")
        if p.get("description"):
            print(f"{'':20} {p['description']}")
    return 0


def cmd_validate(a) -> int:
    files = [Path(x) for x in a.files] or pipeline_files()
    bad = 0
    for f in files:
        errs = validate_pipeline(yaml_load(f), f)
        for e in errs:
            print(f"ERROR {rel(f)}: {e}")
        bad += len(errs)
    print(f"pipelines: {len(files)} file(s), {bad} error(s)")
    return 1 if bad else 0


def new_or_resume_run(p: dict, sha: str, fresh: bool) -> dict:
    base = f"{p['id']}-{sha[:8]}"
    run_id = base
    n = 1
    while fresh and (run_path(run_id) / "run.json").exists():
        n += 1
        run_id = f"{base}-{n}"
    f = run_path(run_id) / "run.json"
    if f.exists():
        run = json.loads(f.read_text())
        for st in p["stages"]:
            run["stages"].setdefault(st["id"], {"kind": stage_kind(st), "repo": st.get("repo"), "branch": st.get("branch")})
        run["order"] = [st["id"] for st in p["stages"]]
        return run
    t = p["trigger"]
    stages = {st["id"]: {"kind": stage_kind(st), "repo": st.get("repo"), "branch": st.get("branch"), "status": "pending"}
              for st in p["stages"]}
    return {"id": run_id, "pipeline": p["id"], "created": now_iso(),
            "trigger": {"repo": t["repo"], "ref": t["ref"], "sha": sha}, "order": [st["id"] for st in p["stages"]],
            "stages": stages}


def take_lock(name: str):
    d = STATE / "locks" / name
    d.parent.mkdir(parents=True, exist_ok=True)
    try:
        d.mkdir()
    except FileExistsError:
        if time.time() - d.stat().st_mtime > 4 * 3600:
            d.rmdir()
            d.mkdir()
        else:
            raise Fail(f"pipeline {name} is already running (lock {rel(d)})")
    return d


def print_plan(p: dict) -> None:
    t = p["trigger"]
    print(f"pipeline {p['id']}: on {t['repo']}@{t['ref']} ({t.get('on_change', 'notify')} when it moves)")
    for st in p["stages"]:
        k = stage_kind(st)
        if k == "deploy":
            dep = st["deploy"]
            sites = ", ".join(f"{s['site']}:{s['host']}" for s in sites_tracking(dep["repo"], dep["ref"])) or "none"
            print(f"  {st['id']}: after {', '.join(st.get('needs') or []) or '-'}; devops deploy <site> {dep['procedure']} on sites tracking {dep['repo']}@{dep['ref']}: {sites}")
            continue
        upd = st["update"]
        what = f"submodule {upd['submodule']} -> trigger sha" if k == "submodule" else f"merge {upd['merge']}"
        pub = st.get("publish") or {}
        print(f"  {st['id']}: {st['repo']}@{st['branch']}: {what}")
        if st.get("setup"):
            print(f"      setup:  {'; '.join(st['setup'])}")
        checks = []
        for kind, cfg in check_items(st):
            if kind == "sed-anchors":
                checks.append(f"sed-anchors {cfg['script']} (require {cfg.get('require', 'all')}, "
                              f"{len(cfg.get('expect_files') or [])} expected files)")
            else:
                checks.append(cfg.get("run", kind))
        print(f"      check:  {'; '.join(checks) or '-'}")
        if st.get("fix"):
            print(f"      fix:    agent with skill {st['fix']['skill']} (up to {st['fix'].get('attempts', 2)} attempts)")
        if st.get("verify"):
            print(f"      verify: {'; '.join(st['verify'])}")
        print(f"      publish (approval, tier {3 if pub.get('tag') else pub.get('tier', 2)}): push {st['branch']}"
              + (" + next patch tag" if pub.get("tag") else "") + (f"; {pub['triggers']}" if pub.get("triggers") else ""))


def cmd_run(a) -> int:
    p = load_pipeline(a.pipeline)
    if a.dry_run:
        print_plan(p)
        return 0
    t = p["trigger"]
    sha = a.sha or ls_remote(repo_url(t["repo"], t.get("url")), t["ref"])
    if not re.match(r"^[0-9a-f]{40}$", sha):
        raise Fail("--sha must be a full 40-character commit")
    if a.sha and not a.force:
        td = ensure_clone(t["repo"], repo_url(t["repo"], t.get("url")))
        git(td, "fetch", "--quiet", "origin")
        if sh(["git", "-C", str(td), "cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0 \
                or not is_ancestor(td, sha, f"origin/{t['ref']}"):
            raise Fail(f"{sha[:8]} is not on {t['repo']}@{t['ref']}; --force propagates it anyway")
    lock = take_lock(p["id"])
    try:
        run = new_or_resume_run(p, sha, a.fresh)
        say(f"run {run['id']}: {t['repo']}@{t['ref']} {sha[:8]}  (agent runner: {pick_runner() or 'none'})")
        only = set(a.stage or [])
        unknown = only - set(run["order"])
        if unknown:
            raise Fail(f"unknown stage(s): {', '.join(sorted(unknown))}")
        for st in p["stages"]:
            sid = st["id"]
            S = run["stages"][sid]
            if only and sid not in only:
                continue
            if S.get("status") == "published":
                say(f"{sid}: published already; skipping")
                continue
            if not only and S.get("status") in ("ready", "up_to_date") and S.get("kind") != "deploy":
                say(f"{sid}: {S['status']} (re-prepare with --stage {sid})")
                continue
            say(f"{sid}:")
            try:
                if S["kind"] == "deploy":
                    prepare_deploy_stage(run, st, a)
                else:
                    prepare_repo_stage(run, st, a)
            except Fail as e:
                S["status"] = "failed"
                S["error"] = str(e)
                say(f"  FAILED: {str(e).splitlines()[0]}")
            save_run(run)
        save_run(run)
        summary(run)
        return 1 if any(run["stages"][s].get("status") in ("failed", "needs_fix") for s in run["order"]) else 0
    finally:
        lock.rmdir()


def summary(run: dict) -> None:
    print(f"\nrun {run['id']} ({run['trigger']['repo']}@{run['trigger']['ref']} {run['trigger']['sha'][:8]})")
    for sid in run["order"]:
        S = run["stages"][sid]
        extra = S.get("note") or ""
        if S.get("commit"):
            extra = f"commit {S['commit'][:8]} {S.get('subject', '')}" + (f", tag {S['tag']}" if S.get("tag") else "")
        if S.get("status") == "failed":
            extra = (S.get("error") or "").splitlines()[0]
        print(f"  {sid:12} {S.get('status', 'pending'):11} {extra}")
        for w in S.get("warnings") or []:
            print(f"  {'':12} warning: {w}")
        n = next_step(run, sid)
        if n and S.get("status") != "waiting":
            print(f"  {'':12} next: {n}")
    print(f"report: {run.get('report')}")


def cmd_show(a) -> int:
    run = load_run(a.run)
    if not a.stage:
        save_run(run)
        print((ROOT / run["report"]).read_text())
        return 0
    if a.stage not in run["stages"]:
        raise Fail(f"run {run['id']} has no stage {a.stage}")
    sdir = run_path(run["id"]) / a.stage
    want = {"diff": "diff.patch", "check": "check.md", "prompt": "prompt.md", "log": "log.txt", "verify": "verify.log"}
    if a.agent:
        logs = sorted(sdir.glob("agent-*.log"))
        if not logs:
            raise Fail("no agent output for this stage")
        for f in logs:
            print(f"== {f.name}\n{f.read_text()}")
            df = f.with_suffix(".diff")
            if df.exists():
                print(f"== {df.name}\n{df.read_text()}")
        return 0
    which = next((k for k in want if getattr(a, k)), None)
    if which:
        f = sdir / want[which]
        if not f.exists():
            raise Fail(f"no {which} for {a.stage} yet ({rel(f)})")
        print(f.read_text())
        return 0
    print(json.dumps(run["stages"][a.stage], indent=2))
    print(f"\nfiles: {rel(sdir)}/  (--diff --check --prompt --agent --log --verify)")
    n = next_step(run, a.stage)
    if n:
        print(f"next: {n}")
    return 0


def find_stage(p: dict, sid: str) -> dict:
    for st in p["stages"]:
        if st["id"] == sid:
            return st
    raise Fail(f"pipeline {p['id']} has no stage {sid}")


def cmd_publish_plan(a) -> int:
    run = load_run(a.run)
    p = load_pipeline(run["pipeline"])
    st = find_stage(p, a.stage)
    S = run["stages"][a.stage]
    if S.get("status") != "ready":
        raise Fail(f"stage {a.stage} is {S.get('status', 'pending')}, not ready" + (f": {next_step(run, a.stage)}" if next_step(run, a.stage) else ""))
    if S["kind"] == "deploy":
        pend = [s for s, v in S["sites"].items() if v["status"] not in ("deployed", "up_to_date")]
        site = a.site or (pend[0] if pend else None)
        if not site or site not in S["sites"]:
            raise Fail(f"choose a site: {', '.join(S['sites'])}")
        print(json.dumps({"kind": "deploy", "site": site, "procedure": S["procedure"], "target": S["target"]}))
        return 0
    url = repo_url(st["repo"], st.get("url"))
    d = WORK / st["repo"]
    git(d, "fetch", "--quiet", "origin", st["branch"])
    remote = git(d, "rev-parse", f"origin/{st['branch']}")
    if remote != S["base"]:
        raise Fail(f"{st['repo']}@{st['branch']} moved since prepare ({S['base'][:8]} -> {remote[:8]}); "
                   f"re-prepare: devops pipeline run {run['pipeline']} --stage {a.stage}")
    pub = st.get("publish") or {}
    actions = [f"git -C {shlex.quote(str(d))} push {url} {S['commit']}:refs/heads/{st['branch']}"]
    tier = int(pub.get("tier", 2))
    if pub.get("tag") == "next-patch":
        tag, after = next_patch_tag(url)
        S["tag"], S["tag_after"] = tag, after
        save_run(run)
        actions.append(f"git -C {shlex.quote(str(d))} tag -a {tag} -m 'Release {tag}' {S['commit']}")
        actions.append(f"git -C {shlex.quote(str(d))} push {url} refs/tags/{tag}")
        tier = 3
    title = f"pipeline {run['id']}: publish {a.stage} to {st['repo']}@{st['branch']}" + (f" and tag {S['tag']}" if S.get("tag") else "")
    rewind = next((w for w in S.get("warnings") or [] if " back " in w), None)
    if rewind:
        title += f" (REWIND: {rewind})"
    a = S.get("agent") or {}
    extra = "\n".join([S.get("subject", ""), tail(S.get("files", ""), 30)]
                      + ([f"agent: {a.get('runner')} edited this ({a.get('attempts')} attempt(s), {a.get('result')})"] if a.get("attempts") else [])
                      + [f"warning: {w}" for w in S.get("warnings") or []])
    rollback = f"git revert {S['commit'][:8]} on {st['branch']} and push" + (
        f"; a pushed tag starts a release that cannot be recalled once built (delete tag {S.get('tag')} and its GitHub release by hand)" if S.get("tag") else "")
    print(json.dumps({"kind": "git", "tier": tier, "title": title, "action": "\n".join(actions),
                      "effect": pub.get("triggers") or f"updates {st['repo']}@{st['branch']}",
                      "rollback": rollback, "verify": f"devops pipeline status {run['pipeline']}", "extra": extra}))
    return 0


def cmd_publish_exec(a) -> int:
    run = load_run(a.run)
    p = load_pipeline(run["pipeline"])
    st = find_stage(p, a.stage)
    S = run["stages"][a.stage]
    if S.get("status") != "ready" or S["kind"] == "deploy":
        raise Fail(f"stage {a.stage} is not a ready repo stage")
    url = repo_url(st["repo"], st.get("url"))
    d = WORK / st["repo"]
    logf = stage_dir(run, a.stage) / "log.txt"
    git(d, "fetch", "--quiet", "origin", st["branch"], logf=logf)
    if git(d, "rev-parse", f"origin/{st['branch']}") != S["base"]:
        raise Fail(f"{st['branch']} moved on the remote since prepare; re-prepare the stage")
    if git(d, "rev-parse", "--verify", f"{S['commit']}^{{commit}}", check=False) != S["commit"]:
        raise Fail(f"prepared commit {S['commit'][:8]} is gone from {d}; re-prepare the stage")
    if S.get("tag"):
        tag, _ = next_patch_tag(url)
        if tag != S["tag"]:
            raise Fail(f"the next tag is now {tag}, not the approved {S['tag']}; re-run publish for a new approval")
    noprompt = {"GIT_TERMINAL_PROMPT": "0"}
    sh(["git", "-C", str(d), "push", url, f"{S['commit']}:refs/heads/{st['branch']}"], env=noprompt, logf=logf, timeout=300)
    say(f"pushed {S['commit'][:8]} to {st['repo']}@{st['branch']}")
    if S.get("tag"):
        sh(["git", "-C", str(d), "tag", "-f", "-a", S["tag"], "-m", f"Release {S['tag']}", S["commit"]], logf=logf)
        sh(["git", "-C", str(d), "push", url, f"refs/tags/{S['tag']}"], env=noprompt, logf=logf, timeout=300)
        say(f"pushed tag {S['tag']}")
    S["status"] = "published"
    S["published_at"] = now_iso()
    S["phase"] = "done"
    save_run(run)
    for other in p["stages"]:
        if a.stage in (other.get("needs") or []):
            print(f"next: devops pipeline run {run['pipeline']} --stage {other['id']}")
    return 0


def cmd_deploy_record(a) -> int:
    run = load_run(a.run)
    S = run["stages"][a.stage]
    v = S["sites"][a.site]
    cur = deployed_sha(a.site, v["host"], v["path"])
    v["deployed"] = cur
    v["status"] = "deployed" if cur == S["target"] else "mismatch"
    if all(x["status"] in ("deployed", "up_to_date") for x in S["sites"].values()):
        S["status"] = "published"
        S["published_at"] = now_iso()
    save_run(run)
    if v["status"] != "deployed":
        say(f"WARN {a.site} is at {(cur or 'unknown')[:8]}, expected {S['target'][:8]} (did the branch move?)")
        return 1
    say(f"{a.site} now runs {cur[:8]}")
    return 0


def cmd_status(a) -> int:
    files = [PIPELINES / f"{a.pipeline}.yaml"] if a.pipeline else pipeline_files()
    print(f"agent runner: {pick_runner() or 'none (fix steps write a prompt for you)'}")
    for f in files:
        p = load_pipeline(f.stem)
        t = p["trigger"]
        sha = ls_remote(repo_url(t["repo"], t.get("url")), t["ref"])
        print(f"\n{p['id']}: {t['repo']}@{t['ref']} is {sha[:8]}")
        for st in p["stages"]:
            k = stage_kind(st)
            try:
                if k == "deploy":
                    dep = st["deploy"]
                    if not a.deployed:
                        sites = ", ".join(s["site"] for s in sites_tracking(dep["repo"], dep["ref"])) or "none"
                        print(f"  {st['id']:12} {sites} (add --deployed to read each checkout over ssh)")
                        continue
                    head = ls_remote(repo_url(dep["repo"], dep.get("url")), dep["ref"])
                    for s in sites_tracking(dep["repo"], dep["ref"]):
                        cur = deployed_sha(s["site"], s["host"], s["path"])
                        state = "current" if cur == head else f"behind {dep['ref']} {head[:8]}"
                        print(f"  {st['id']:12} {s['site']}:{s['host']} runs {(cur or 'unknown')[:8]}: {state}")
                    continue
                url = repo_url(st["repo"], st.get("url"))
                d = ensure_clone(st["repo"], url)
                git(d, "fetch", "--quiet", "origin", st["branch"])
                ref = f"origin/{st['branch']}"
                if k == "submodule":
                    path = st["update"]["submodule"]
                    pin = pin_of(d, ref, path)
                    state = "current" if pin == sha else f"behind (pins {(pin or 'none')[:8]})"
                    line = f"  {st['id']:12} {st['repo']}@{st['branch']} {state}"
                    if (st.get("publish") or {}).get("tag"):
                        tags = remote_tags(url)
                        if tags:
                            name = tags[-1][1]
                            git(d, "fetch", "--quiet", "--no-tags", "origin", f"refs/tags/{name}:refs/tags/{name}", check=False)
                            tpin = pin_of(d, name, path)
                            line += f"; latest tag {name} " + ("includes it" if tpin == sha else f"pins {(tpin or '?')[:8]} (release pending)")
                    print(line)
                else:
                    if sh(["git", "-C", str(d), "cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0:
                        git(d, "fetch", "--quiet", "origin", t["ref"])
                    if is_ancestor(d, sha, ref):
                        print(f"  {st['id']:12} {st['repo']}@{st['branch']} contains {sha[:8]} ({git(d, 'rev-list', '--count', f'{sha}..{ref}')} commits of its own)")
                    else:
                        print(f"  {st['id']:12} {st['repo']}@{st['branch']} behind by {git(d, 'rev-list', '--count', f'{ref}..{sha}')} commit(s)")
            except Fail as e:
                print(f"  {st['id']:12} unknown: {str(e).splitlines()[0]}")
        lf = STATE / f"{p['id']}.latest"
        if lf.is_file():
            try:
                run = load_run(lf.read_text().strip())
                states = ", ".join(f"{s}={run['stages'][s].get('status', 'pending')}" for s in run["order"])
                print(f"  last run {run['id']} ({run.get('updated')}): {states}")
            except Fail:
                pass
    return 0


def cmd_watch(_a) -> int:
    for f in pipeline_files():
        p = load_pipeline(f.stem)
        t = p["trigger"]
        url = repo_url(t["repo"], t.get("url"))
        try:
            sha = ls_remote(url, t["ref"])
        except Fail as e:
            print(f"ERROR {p['id']} {t['repo']}@{t['ref']}: {e}")
            continue
        seen_f = STATE / f"{p['id']}.last_seen"
        STATE.mkdir(parents=True, exist_ok=True)
        last = seen_f.read_text().strip() if seen_f.is_file() else ""
        seen_f.write_text(sha + "\n")
        if not last:
            print(f"FIRST {p['id']} {t['repo']}@{t['ref']} {sha[:8]}")
            continue
        if last == sha:
            print(f"SAME {p['id']} {t['repo']}@{t['ref']} {sha[:8]}")
            continue
        d = ensure_clone(t["repo"], url)
        git(d, "fetch", "--quiet", "origin", t["ref"], check=False)
        log_text = git(d, "log", "--oneline", f"{last}..{sha}", check=False)
        print(f"MOVED {p['id']} {t['repo']}@{t['ref']} {last[:8]} -> {sha[:8]} ({len(log_text.splitlines())} commits)")
        for line in log_text.splitlines()[:15]:
            print(f"  {line}")
        if t.get("on_change", "notify") == "prepare":
            ns = argparse.Namespace(pipeline=p["id"], stage=None, sha=sha, cont=False, force=False, fresh=False,
                                    no_agent=False, dry_run=False)
            try:
                cmd_run(ns)
            except Fail as e:
                print(f"  prepare failed: {e}")
    return 0


def main(argv) -> int:
    ap = argparse.ArgumentParser(prog="devops pipeline")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    v = sub.add_parser("validate")
    v.add_argument("files", nargs="*")
    s = sub.add_parser("status")
    s.add_argument("pipeline", nargs="?")
    s.add_argument("--deployed", action="store_true")
    r = sub.add_parser("run")
    r.add_argument("pipeline")
    r.add_argument("--stage", action="append")
    r.add_argument("--sha")
    r.add_argument("--continue", dest="cont", action="store_true")
    r.add_argument("--force", action="store_true")
    r.add_argument("--fresh", action="store_true")
    r.add_argument("--no-agent", action="store_true")
    r.add_argument("--dry-run", action="store_true", default=bool(os.environ.get("DEVOPS_DRY_RUN")))
    sh_ = sub.add_parser("show")
    sh_.add_argument("run", nargs="?")
    sh_.add_argument("stage", nargs="?")
    for flag in ("diff", "check", "prompt", "agent", "log", "verify"):
        sh_.add_argument(f"--{flag}", action="store_true")
    pp = sub.add_parser("publish-plan")
    pp.add_argument("run")
    pp.add_argument("stage")
    pp.add_argument("--site")
    pe = sub.add_parser("publish-exec")
    pe.add_argument("run")
    pe.add_argument("stage")
    dr = sub.add_parser("deploy-record")
    dr.add_argument("run")
    dr.add_argument("stage")
    dr.add_argument("site")
    sub.add_parser("watch")
    dc = sub.add_parser("discard")
    dc.add_argument("run")
    dc.add_argument("stage", nargs="*")
    ca = sub.add_parser("check-anchors")
    ca.add_argument("dir")
    ca.add_argument("script")
    ca.add_argument("--copy", action="append", default=[], help="SRC:DST relative to dir")
    ca.add_argument("--expect", action="append", default=[], help="a file the script must edit")
    ca.add_argument("--require", choices=["all", "script"], default="all")
    a = ap.parse_args(argv)
    fn = {"list": cmd_list, "validate": cmd_validate, "status": cmd_status, "run": cmd_run, "show": cmd_show,
          "publish-plan": cmd_publish_plan, "publish-exec": cmd_publish_exec, "deploy-record": cmd_deploy_record,
          "watch": cmd_watch, "discard": cmd_discard, "check-anchors": cmd_check_anchors}[a.cmd]
    try:
        return fn(a)
    except Fail as e:
        say(f"ERROR {e}")
        return 1


def cmd_discard(a) -> int:
    """Mark prepared stages so they cannot be published; the clones reset on the next run."""
    run = load_run(a.run)
    for sid in a.stage or run["order"]:
        if sid not in run["stages"]:
            raise Fail(f"run {run['id']} has no stage {sid}")
        S = run["stages"][sid]
        if S.get("status") in ("published", "deployed") or S.get("kind") == "deploy":
            continue
        if S.get("status") in ("ready", "needs_fix", "failed"):
            S["status"], S["note"] = "discarded", f"discarded {now_iso()}; the next run re-prepares it"
            say(f"  {sid}: discarded")
    save_run(run)
    return 0


def cmd_check_anchors(a) -> int:
    d = Path(a.dir).resolve()
    copies = dict(c.split(":", 1) for c in a.copy)
    sdir = Path(tempfile.mkdtemp(prefix="devops-anchors-log-"))
    ok, text = check_sed_anchors({"script": a.script, "copy": copies, "expect_files": a.expect, "require": a.require},
                                 d, sdir / "log.txt")
    print(text)
    shutil.rmtree(sdir, ignore_errors=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
