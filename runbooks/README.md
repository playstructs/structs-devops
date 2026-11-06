# Runbooks

Network-wide runbooks live here; site-specific ones live in
`inventory/sites/<site>/runbooks/`. Repeatable work should become a procedure
in the site's `site.yaml` and run through `devops deploy` (see `deploy/README.md`);
a runbook explains the why and the manual fallback.


| Runbook | Use when |
|---|---|
| [deploy/README.md](deploy/README.md) | Running or writing a procedure (`devops deploy`) |
| [deploy/local-docker.md](deploy/local-docker.md) | Running the guild stack on the hub against the public node |
| [deploy/new-guild.md](deploy/new-guild.md) | Standing up a new guild site end to end |
| [deploy/public-node.md](deploy/public-node.md) | Building or rebuilding a public archive node |
| [deploy/webapp-update.md](deploy/webapp-update.md) | Pulling a new webapp build onto a guild |
| [chain-upgrade.md](chain-upgrade.md) | A software upgrade proposal passed; stage, monitor, verify |
| [cosmovisor-recovery.md](cosmovisor-recovery.md) | A node halted at an upgrade height or the `current` symlink is wrong |
| [post-recreate-app-toml-fix.md](post-recreate-app-toml-fix.md) | structsd was recreated and the public node lost its app.toml overrides |
| [tls-cert-renewal.md](tls-cert-renewal.md) | Certificates on the public node (certbot standalone + Caddy) |

Write new runbooks from `templates/runbook.md`. Record incidents with
`templates/incident-report.md` in `inventory/reports/incidents/`.
