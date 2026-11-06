---
name: structs-dev-translations
description: Updates a structs-webapp translation overlay (structs-kor's ko/ for Korean, structs-webapp-bra's ptbr/ for Brazilian Portuguese) after the structs-webapp submodule moved. Fixes what the overlay audit reports - stale entries whose English changed, new untranslated English, orphaned strings files, broken or mismatched translations, stale banner or font art - following the overlay README and glossary. Use when npm test or the audit fails in structs-kor or structs-webapp-bra, when the translation pipeline stage is needs_fix, or when asked to translate new webapp text.
---

# Translation overlays

Both repos build structs-webapp's own client with an overlay applied while
webpack reads the sources; the `structs-webapp/` submodule is never edited.
`strings/<upstream path>.json` maps exact upstream text to its translation.
`npm test` runs the audit in strict mode and fails while anything remains.

| Repo | Overlay | Audit | Runtime helper |
|---|---|---|---|
| structs-kor | `ko/` | `npm run audit:ko` | `__ko.t()` |
| structs-webapp-bra | `ptbr/` | `npm run audit:ptbr` | `__ptbr.t()` |

## When to use

- The pipeline stage for kor or bra is `needs_fix` (the task prompt has the
  audit output, upstream commits and changed files).
- The user asks to translate new webapp text by hand.

## Procedure

1. Read `<overlay>/README.md` and `<overlay>/GLOSSARY.md` before writing.
   They are the source of truth; follow them over anything here.
2. Run the audit; work through it one upstream file at a time. Check a file
   with `node <overlay>/audit.cjs <upstream path>`.
3. By report:
   - `stale`: the English key changed upstream. Find the new text in
     `structs-webapp/src/<path>` (the upstream diff shows the old and new),
     update the key to the exact new text, and the translation to match.
     For banner frames or fonts, run the script the audit names
     (`<overlay>/art/banners.py`, `ptbr/art/fonts.py`).
   - `untranslated`: new player-visible English. Add it to the matching
     strings file, or `$keep` it if it stays English on purpose (names,
     units, ids).
   - `orphan`: the upstream file is gone. Move the entries to the file the
     code moved to, or delete the strings file.
   - `broken` / `mismatch`: the translation no longer fits its code
     (expressions, quotes, tags). Fix the entry.
4. Keys must only match what a player reads: include quotes or tags around
   the text so ids, classes, selectors, event names, storage keys and values
   sent to the guild or chain never change.
5. Keep `${…}` expressions, tags and attributes; reorder as the language
   needs. Text used as a value in code stays English and is translated where
   shown through the runtime helper plus `runtime/terms.json`. Never in
   `js/workers/` or what it imports.
6. Use the glossary's words and voice. Korean: 합니다체 for narration, short
   nouns for buttons, particles that fit after `${name}`. Portuguese:
   agreement, plurals and a/an handled in the key; only the characters the
   pixel fonts have (the audit reports others).
7. Re-run `npm test` until it passes, then `npm run build`.

## Rules

- Edit only the overlay directory (`ko/` or `ptbr/`). Never edit
  `structs-webapp/`, `package.json` or the workflows.
- Do not commit; the pipeline commits the overlay together with the
  submodule pointer after the user reviews it.
- When unsure of a translation, keep it close to the glossary and list it in
  your summary so the user can ask a native speaker.

## Verification

`npm test` passes (no stale, untranslated, orphan, broken or mismatch) and
`npm run build` completes.
