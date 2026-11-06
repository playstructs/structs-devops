---
name: structs-dev-anchors
description: Fixes structs-desktop's scripts/apply-patches.sh after a structs-webapp update moved the code its sed anchors match. The script patches a copy of the webapp source (endpoint overrides via window.__STRUCTS_CONFIG__, GrassManager resume bridge, banner canvas renderer, window.gameState and the reactor, TaskManager overrides, SigningClientManager helpers) and guards each patch with verify_patched. Use when the desktop pipeline stage fails its sed-anchors check, sync.sh stops with "sed did not apply", or a webapp refactor renamed or moved a file the desktop patches.
---

# Desktop patch anchors

structs-desktop builds the game client from its `structs-webapp/` submodule.
`scripts/sync.sh` copies `structs-webapp/src/js` to `.build-tmp/js`, runs
`scripts/apply-patches.sh .build-tmp`, then webpack. Each `sed` in
`apply-patches.sh` finds an anchor (a line of upstream code) and rewrites it;
`verify_patched` (or a `grep -q`) right after it fails the build when the
marker is missing. The submodule itself is never edited.

## When to use

- The pipeline check prints `ERROR: <desc> — sed did not apply`, `NO FILE`,
  or `NOT RUN <file>`.
- A webpack error after patching points at patched code.

## Procedure

1. Read the failed check: which description failed, which file.
2. Find where the anchored code went in the new upstream source:
   `git -C structs-webapp log -p -- src/js/<file>` (or grep
   `structs-webapp/src/js` for a distinctive part of the old anchor).
   The upstream commit list and changed files are in the task prompt.
3. Change the `sed` so it matches the new shape and produces the same
   behavior. Keep the intent of each patch:
   - endpoint overrides: `window.__STRUCTS_CONFIG__?.<key>` first, then the
     webapp's own value (`guildApi`, `grassNatsWs`, `clientWs`);
   - banners: canvas renderer and `imageSmoothingEnabled = false`;
   - `window.gameState`, `window.grassManager`, `__STRUCTS_REACTOR__`,
     `__STRUCTS_TASK_OVERRIDES__`: exposures the Tauri side calls.
4. When upstream keeps two shapes alive (older and newer), keep both seds,
   as the script already does for `SigningClientManager.js`, and keep one
   `verify_patched` that either satisfies.
5. If a file moved, update its path in the script and in the
   `expect_files` list of the pipeline (tell the user; that list lives in the
   devops workspace, not in this repo).
6. If upstream now does natively what a patch added, remove that patch and
   its guard, and say so in the summary; check `src-tauri/` and
   `frontend/structs-config.js` for code that depended on it.
7. Re-run the check command from the task prompt until it passes, then
   `bash scripts/sync.sh` if you can, to see webpack succeed.

## Rules

- Edit `scripts/apply-patches.sh` (and, only if needed, `frontend/` or
  `src-tauri/` code that uses a patched name). Never edit `structs-webapp/`.
- Every sed keeps a guard that fails loudly. Never remove a guard to make a
  check pass.
- Keep `sed -i.bak` (works with BSD and GNU sed) and the `.bak` cleanup.
- Do not commit, tag or bump versions; the release workflow takes the
  version from the tag.

## Verification

The pipeline's sed-anchors check passes with no `NO FILE` / `NOT RUN` rows,
and `sync.sh` completes its webpack build.
