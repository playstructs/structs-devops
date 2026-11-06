---
name: structs-inventory
description: Catalogues Structs infrastructure in the site.yaml inventory format (hosts, stacks, services, image digests, source pins, structsd nodes, endpoints, TLS, on-chain ids, secret pointers, procedures, thresholds, known issues), records changes, and scaffolds new sites. Use when adding or describing a site or host, after any change on a host, when inventory-freshness warns, when something in the inventory looks wrong, or when asked what runs where.
---

# Structs inventory

The inventory is the operator's own repo and the source of truth that every
tool reads: `inventory/` by default, or wherever `DEVOPS_INVENTORY` points
(`devops context` prints its `AGENTS.md`). The format is specified in
[docs/inventory.md](../../../docs/inventory.md); `examples/inventory/` is a
fictional one. Only record what was confirmed on a host or the chain;
inferred values go under `unverified:` until checked.

## When to use

- After any change: new image digest, branch or commit, env setting, id, endpoint.
- A new site, host, guild, validator or public node.
- `inventory-freshness` warns (stale `last_verified`, unverified fields).
- Answering "what runs where?" (read the generated READMEs first).
- No inventory yet: `devops init` creates one from `templates/inventory/`.

## Decisions

| Need | Command |
|---|---|
| See what exists | `devops site list`, `devops inventory show <site>` |
| Compare with reality | `devops inventory discover <site>` (read-only ssh), `devops ps <site>`, `devops node <site> status` |
| New site | `devops site new <id> --kind guild|public-node|local --fqdn F --ip I --ssh T` |
| Record a change | edit `site.yaml`, add a CHANGELOG line, render |
| Chain-wide change | public facts (binary, upgrades, endpoints, default thresholds) in the framework's `networks/<preset>.yaml`; your own (images, peers, voters, public-node site, threshold overrides) in `inventory/network.yaml` |
| Change a framework file | `devops publish-check` before it leaves the hub: no site ids, hosts, IPs or branches from the inventory |

## Procedure

1. Gather facts read-only: `devops inventory discover <site>`, `devops ps`,
   `devops webapp <site> status`, `devops node <site> status`,
   `devops onchain <site> show`.
2. Edit `inventory/sites/<site>/site.yaml`. Keep ids stable; host ids are
   unique across all sites. Secrets: pointers only (`host-env:`,
   `host-file:`, `host-volume:`, `local-env:`) with criticality, backup,
   rotation.
3. Bump `last_verified` when you confirmed the whole file; otherwise list
   what you did not confirm under `unverified:`.
4. Add a dated line at the top of the site `CHANGELOG.md`: what changed, why,
   who approved (if tier 2+).
5. `devops inventory validate` (must have 0 errors), then
   `devops inventory render` to refresh the generated blocks in the
   inventory's `AGENTS.md` and the site README.
6. New site: fill in the template, add the site's narrative to its
   README above the generated block, and add it to `network.yaml`
   `gov.voters` or `public_node_site` if it votes or serves the public endpoints.

## Commands reference

```bash
devops site list
devops inventory show <guild>
devops inventory discover <guild>
devops site new my-guild --kind guild --fqdn guild.example.com --ip 203.0.113.10 --ssh root@guild.example.com
devops inventory validate
devops inventory render
devops inventory render --check     # exit 1 when generated blocks are stale
```

## Verification

`devops inventory validate` reports 0 errors; `render --check` is clean;
`devops check inventory-freshness` is OK or only warns about known gaps.

## Errors

| Validator message | Fix |
|---|---|
| `looks like a secret value` | move it to `secrets:` as a pointer; scrub the value from history if committed |
| `host id ... used by more than one site` | rename one host id (and every ref to it) |
| `target uses ${X} but host_env has no X` | add `X` under `host_env` |
| `gov voter ... is not in onchain.accounts` | add the account (address + secret pointer) |
| `critical secret ... has no off-host backup` (warning) | record where the offline copy is, or tell the user it is missing |

## See also

- [docs/inventory.md](../../../docs/inventory.md), [templates/site/](../../../templates/site/guild/site.yaml), [examples/inventory/](../../../examples/inventory/AGENTS.md)
- `structs-secrets`, `structs-deploy`
