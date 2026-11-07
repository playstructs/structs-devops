---
name: structs-handoff
description: Ends a Structs infrastructure session by recording what changed, what to watch and open follow-ups in the ops journal, and checking that the inventory and generated docs are current. Use when finishing a session, before switching tools or people, or after any change, incident or vote.
disable-model-invocation: true
---

# Hand off

## Procedure

1. **What changed.** Review this session's entries:
   `grep "$(date -u +%Y-%m-%d)" inventory/reports/audit.log` (tier 1+
   actions and transaction approvals), `inventory/reports/tx-log/<date>.tsv`
   (transactions), run reports in `inventory/reports/runs/<date>/`, and
   anything you did by hand on a host.
2. **Inventory.** For every change, confirm `site.yaml` and the site
   `CHANGELOG.md` say so. `devops inventory validate` and
   `devops inventory render --check` (render if stale).
3. **Still red.** `devops health all --no-notify` if anything was changed; list
   the WARN/CRIT that remain and whether each is known.
4. **Write the entry:**

   ```bash
   devops journal add --site <guild> --title "<one line>" <<'EOF'
   Changed: ...
   Verified: ...
   Watch: ... (which check, until when)
   Follow-ups: ... (owner if known)
   EOF
   ```

   Pointers and states only; never values.
5. Tell the user the summary in two or three sentences.
