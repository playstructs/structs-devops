#!/usr/bin/env python3
"""Classify a shell command against tools/agents/policy.tsv.

  classify.py [--json] -- <command string>
  echo "<command>" | classify.py [--json]

Prints "<tier> <reason>" (tier is 0-3, or S for refused secret access).
Exit code: 0 for tier 0, 1 for tier 1, 2 for tier 2, 3 for tier 3, 4 for S.
"""
from __future__ import annotations

import json
import re
import shlex
import sys
from pathlib import Path

POLICY = Path(__file__).with_name("policy.tsv")
SPLIT = re.compile(r"\|\||&&|;|\||\n")


def load():
    secret, regex, allow = [], [], []
    for line in POLICY.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        tier, kind, pat = parts[0], parts[1], parts[2]
        reason = parts[3] if len(parts) > 3 else ""
        if kind == "secret":
            secret.append((re.compile(pat), reason))
        elif kind == "re":
            regex.append((int(tier), re.compile(pat), reason))
        elif kind == "cmd":
            allow.append(pat.split())
    return secret, regex, allow


def strip_wrappers(cmd: str) -> str:
    """Unwrap `ssh host 'cmd'`, `bash -lc 'cmd'`, `su - u -c 'cmd'`, sudo."""
    for _ in range(4):
        try:
            words = shlex.split(cmd, posix=True)
        except ValueError:
            return cmd
        if not words:
            return cmd
        if words[0] == "sudo":
            i = 1
            while i < len(words) and words[i].startswith("-"):
                i += 2 if words[i] in ("-u", "-g", "-C", "-D", "-h", "-p", "-U", "-r", "-t") else 1
            cmd = shlex.join(words[i:])
            continue
        if words[0] == "ssh":
            rest = [w for w in words[1:]]
            i = 0
            while i < len(rest) and rest[i].startswith("-"):
                i += 2 if rest[i] in ("-o", "-i", "-p", "-l", "-J", "-F") else 1
            if i + 1 < len(rest):
                cmd = " ".join(rest[i + 1:])
                continue
            return cmd
        if words[0] in ("bash", "sh", "zsh"):
            j = next((k for k, w in enumerate(words[1:3], 1)
                      if w.startswith("-") and not w.startswith("--") and "c" in w), None)
            if j is not None and j + 1 < len(words):
                cmd = words[j + 1]
                continue
            return cmd
        if words[0] == "su" and "-c" in words:
            cmd = words[words.index("-c") + 1]
            continue
        return cmd
    return cmd


SEPARATORS = {";", ";;", "&&", "||", "|", "|&", "&"}


def split_segments(cmd: str) -> list[str]:
    """Split on ; && || | & and newlines outside quotes; regex fallback."""
    try:
        lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return [s.strip() for s in SPLIT.split(cmd) if s.strip()]
    segs, cur = [], []
    for tok in tokens:
        if tok in SEPARATORS:
            if cur:
                segs.append(shlex.join(cur))
            cur = []
        else:
            cur.append(tok)
    if cur:
        segs.append(shlex.join(cur))
    return segs


EXEC_ARG_FLAGS = {"-u", "--user", "-e", "--env", "-w", "--workdir", "--env-file"}
COMPOSE_ARG_FLAGS = {"-f", "--file", "-p", "--project-name", "--project-directory", "--env-file",
                     "--profile", "--ansi", "--progress", "--parallel"}
READ_ONLY_SESSION = re.compile(r"default_transaction_read_only\s*=\s*on")


def segment_allowed(seg: str, allow, depth: int = 0) -> bool:
    try:
        words = shlex.split(seg, posix=True)
    except ValueError:
        words = seg.split()
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        words = words[1:]
    if not words:
        return True
    # A SELECT can still write through a function, so psql is read-only only
    # when the server enforces it for the session.
    if words[0] == "psql":
        return bool(READ_ONLY_SESSION.search(seg))
    # docker exec is as safe as the command it runs.
    if words[:2] == ["docker", "exec"]:
        if depth > 2:
            return False
        i = 2
        while i < len(words) and words[i].startswith("-"):
            i += 2 if words[i] in EXEC_ARG_FLAGS else 1
        inner = words[i + 1:]
        if not inner:
            return False
        if inner[0] == "psql":
            return bool(READ_ONLY_SESSION.search(seg))
        if inner[0] in ("bash", "sh") and len(inner) > 2 and inner[1].startswith("-") and "c" in inner[1]:
            return all(segment_allowed(s, allow, depth + 1) for s in split_segments(inner[2]))
        return segment_allowed(shlex.join(inner), allow, depth + 1)
    # Global compose options (-f file, -p project) sit before the subcommand.
    if words[:2] == ["docker", "compose"]:
        i = 2
        while i < len(words) and words[i].startswith("-"):
            i += 1 if "=" in words[i] or words[i] not in COMPOSE_ARG_FLAGS else 2
        words = words[:2] + words[i:]
    # Other git options (-c alias.x=!cmd, --exec-path, ...) can run commands.
    if words[0] == "git":
        i = 1
        while i < len(words) and words[i].startswith("-"):
            if words[i] == "-C" and i + 1 < len(words):
                i += 2
            elif words[i] == "-c" and i + 1 < len(words) and words[i + 1].startswith("safe.directory="):
                i += 2
            elif words[i] == "--no-pager":
                i += 1
            else:
                return False
        words = ["git"] + words[i:]
    for prefix in allow:
        if words[: len(prefix)] == prefix:
            return True
    return False


def classify(command: str):
    secret, regex, allow = load()
    inner = strip_wrappers(command)
    for text in {command, inner}:
        for pat, reason in secret:
            if pat.search(text):
                return "S", reason
    best, why = -1, ""
    for tier, pat, reason in regex:
        if pat.search(inner) and tier > best:
            best, why = tier, reason
    if best >= 0:
        return str(best), why
    for m in re.finditer(r"\$\(([^()]*)\)|`([^`]*)`|<\(([^()]*)\)", inner):
        sub = next(g for g in m.groups() if g is not None)
        if not all(segment_allowed(s, allow) for s in split_segments(sub)):
            return "2", "command substitution runs a command that is not on the read-only allowlist"
    if all(segment_allowed(s, allow) for s in split_segments(inner)):
        return "0", "read-only allowlist"
    return "2", "not on the read-only allowlist; treat as service-affecting"


def main():
    args = sys.argv[1:]
    as_json = False
    if args and args[0] == "--json":
        as_json, args = True, args[1:]
    if args and args[0] == "--":
        args = args[1:]
    command = " ".join(args) if args else sys.stdin.read()
    tier, reason = classify(command)
    if as_json:
        print(json.dumps({"tier": tier, "reason": reason}))
    else:
        print(f"{tier} {reason}")
    sys.exit(4 if tier == "S" else int(tier))


if __name__ == "__main__":
    main()
