---
name: structs-investigate
description: Investigates a Structs infrastructure problem end to end (scope, evidence snapshot, hop-by-hop bisection with the debugging skills, root cause, a fix proposal, and the write-up). Use when something is broken, slow, or intermittent, a check is red for an unknown reason, users report errors, or an alert needs a root cause.
disable-model-invocation: true
---

# Investigate a problem

## Procedure

1. **Scope.** Which site(s), since when, who is affected, what changed
   recently (`inventory/sites/<site>/CHANGELOG.md`, `devops journal show 3`,
   `reports/audit.log`). Several sites at once usually means the public node
   or the chain.
2. **Measure.** `devops health <site>` and the specific failing check.
3. **Snapshot before touching anything.** `devops debug snapshot <site>`
   (a restart clears `pg_stat_activity` and rotates logs).
4. **Route.** Open `structs-debug` and follow it to the path-specific skill
   (`-http`, `-postgres`, `-chain`, `-indexer`, `-tsa`). Look the symptom up in
   `docs/debugging/symptom-index.md`.
5. **Bisect** along the data path hop by hop (`docs/debugging/data-flows.md`)
   until you find the first hop that is wrong. Collect evidence read-only.
6. **Explain** to the user: the evidence, the root cause (or the top two
   hypotheses and how to tell them apart), and the fix.
7. **Fix** it. `structs-change` has the checklist (baseline, backup, verify, record).
8. **Write up.** User-visible impact: an incident report from
   `templates/incident-report.md`. In all cases: add the signature to
   `docs/debugging/symptom-index.md` and the site's `known_issues`, then
   `structs-handoff`.
