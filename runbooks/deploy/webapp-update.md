# Webapp update on a guild

The webapp runs from a checkout on the host (`WEBAPP_SOURCE`) that is bind-mounted
into `structs-webapp`. An update is: pull the source, put back what the pull
blanked, re-apply the site's patches, rebuild inside the container, re-wire
OIDC, verify.

```bash
devops deploy <site> webapp-update --dry-run
devops deploy <site> webapp-update
```

## Why each step exists

| Step | Reason |
|---|---|
| Back up `src/.env` | The tracked `.env` overwrites local values on pull. |
| `git restore . && git pull --ff-only <branch>` | Patches are applied on top of a clean tree; a dirty tree makes `--ff-only` fail. A site may track its own branch (its `sources:` ref) until that merges to `main` (`new-releases` reports when it has). |
| `env-restore MATRIX_SIGNIN_CLIENT_ID OIDC_ENCRYPTION_KEY` | The pull blanks both; without them Matrix sign-in and stored OIDC tokens break. |
| `host sync` + `patches apply` | Overlays and transforms (guild manifest, GRASS wss URL, signing client, GA4 insert) are re-applied. GA4 is **inserted** into the current `base.html.twig`, never overlaid from an old copy. |
| `npm run build`, `cache:clear` | Assets and Symfony cache inside the container. |
| `oidc-from-tel` | Re-seeds the MAS OIDC client from `structs-tel` and checks discovery. Always after a pull. |
| `patches check`, `check: endpoints` | Proves the overlays held and the site answers. |

## If something fails

- Build fails: `devops logs <site> structs-webapp 200`; the previous assets are still served until the build succeeds.
- Login broken after the update: `devops webapp <site> status` (shows `OIDC_ENCRYPTION_KEY` set/EMPTY), `devops debug oidc-probe <site>`.
- Patch drift (`DRIFT anchor not found`): upstream changed the file. Read the diff in `.references/structs-webapp`, update the overlay or anchor, then `devops patches <site> apply`.
- Roll back: `git -C <src> checkout <previous commit>` on the host (the run report shows it), rebuild, `cache:clear`.
