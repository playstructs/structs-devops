---
name: structs-debug-http
description: Debugs the Structs web path (Caddy, the nginx microcache on 127.0.0.1:8080, Apache/PHP in structs-webapp, the Symfony route) plus structs.app, the GRASS websocket on :1443, and the OIDC chain between the webapp, MAS and Synapse. Bisects hop by hop and names the failing layer. Use when pages time out or return 5xx, the cache never hits, logins fail, the browser shows mixed-content or websocket errors, Caddy will not start or reload, or structs.app returns 502/503.
---

# Debugging the web path

Hops, outside in: public DNS, host IP, Caddy (host systemd), nginx cache
`structs-webapp-cache` on `127.0.0.1:8080`, Apache inside `structs-webapp`,
then the database through PgBouncer. Details in
[docs/debugging/data-flows.md](../../../docs/debugging/data-flows.md).

## When to use

- Slow or hung pages, the "Loading Assets" hang, 502/503/504.
- `X-Cache-Status` never `HIT`, or logout that does not log out.
- Login 500, Matrix sign-in failing, MAS "down".
- Browser console: mixed content, websocket to `:1443` failing.
- Caddy errors after a config change or certificate renewal.

## Decisions

| Symptom | First command |
|---|---|
| Any page error or slowness | `devops debug http-trace <site> <path>` |
| Load or worker exhaustion | `devops check apache-workers <site>`, `devops debug nginx-top <site> --since 30m` |
| Cache behavior | `http-trace` the same `/api/...` path twice within 5 s; the second should be `HIT` |
| Login or Matrix | `devops debug oidc-probe <site>` |
| Websocket | `devops check endpoints <site>` (`grass-wss` expects 400), then `structs-debug-indexer` |
| structs.app | `devops check structs-app <guild>`; `http-trace` does not apply (it is not behind nginx) |

## Procedure

1. `devops debug http-trace <site> <path>`. It prints one row per hop and
   names the first failing layer:
   - `apache-in-container` fails: the app itself. Check worker count, the
     webapp log (`devops logs <site> structs-webapp 300`), then the database
     path with `structs-debug-postgres`.
   - `nginx-8080` fails with Apache fine: the cache container or its config.
   - `caddy-loopback` fails with nginx fine: Caddy config, certificate, or
     upstream address.
   - `host-ip` fails with Caddy fine: firewall or the Caddy bind address.
2. Slow but answering: compare TTFB per hop. Slow at Apache and fast at
   nginx means cache hits are hiding a saturated backend.
3. Traffic shape: `devops debug nginx-top <site>`. A `/page/N` walk is a
   scraper; a "heavy poller" row is one client on one route. When
   `distinct_urls` is close to the request count, every request misses the
   5 s cache. Client addresses come from the logged `X-Forwarded-For`; to
   identify a client, grep the same address in the Synapse/MAS logs of a
   snapshot (`StructsDesktop/comms` plus an MXID means a desktop player).
4. Match the signatures below, then apply the fix through `structs-change`.

## Signatures

| Signature | Cause | Fix |
|---|---|---|
| Apache processes near 450, TTFB high only at the Apache hop, `/api/allocation/*` and `/api/infusion/*` dominate | Desktop polling exhausts workers | `devops deploy <site> quick-recovery` [2]; verify cache HITs |
| `nginx-top` heavy poller on `/api/struct-defender/protected/{id}/page/{id}` with `distinct_urls` ≈ requests, empty user agent | A desktop client walking every struct (seen 2026-11-05: ~1,200 URLs per 30 min, peak 407/min, all cache misses) | Watch `apache-workers`; report upstream to structs-desktop; nginx `limit_req` only if workers saturate [2] |
| Login 500 on `POST /api/player-address/meta`, inet parse error in the log | `X-Forwarded-For` became a list (`$proxy_add_x_forwarded_for`) | Pass `$http_x_forwarded_for` through in the site's nginx overlay, re-apply patches [2]; never use `$proxy_add_x_forwarded_for` |
| `X-Cache-Status: MISS` every time | Session in the cache key, or `Cache-Control: private` honored | Key the cache on the URL only in the site's nginx overlay, re-apply patches [2] |
| Logout cached | `/api/auth/logout` not excluded | Same patch |
| Browser: mixed content `ws://` | Bundle built without the HTTPS patch | Re-apply patches, rebuild webpack in the container [2] |
| `:1443` returns 400 to curl | Healthy (TLS fine, not an upgrade request) | Nothing |
| `systemctl reload caddy` fails | `admin off` | Validate, then restart (`devops deploy <site> caddy-restart`) [2] |
| Caddy will not start: `permission denied` on `privkey.pem` (public node) | certbot dropped the ACL | Deploy hook `00-fix-cert-acls.sh`; [runbooks/tls-cert-renewal.md](../../../runbooks/tls-cert-renewal.md) |
| Caddy: `address already in use` on `:1443`/`:26657` | docker-proxy holds loopback; Caddy needs `bind <public IP>` | Restore the bind line [2] |
| A port is open publicly despite UFW | Docker-published ports bypass UFW | Bind to `127.0.0.1` in compose [2] |
| structs.app 502 | Container down | `cd /root/structs-app && docker compose up -d` [2] |
| structs.app 503 on `/healthz` | Bouncer auth for `structs_app` | `structs-debug-postgres` |
| structs.app 503 on player/OG pages, `/healthz` OK | Page query failing | `devops logs <guild> structs-app 200` |
| `oidc-probe`: discovery 404, `OIDC_ENABLED` false or keys `EMPTY` | Tracked `.env` reset by a pull | `devops webapp <site> env-restore` [1], `oidc-from-tel` [2] |
| `oidc-probe`: `token_probe=401` | Secret mismatch or base64 secret | Hex secret in both `.env` files [2] |
| Synapse crash loop, `signing.key` Permission denied | Not owned by uid 991 | `chown 991:991` the key [1] |

Never run `certbot --dry-run` on the public node: its pre-hook stops Caddy.
Never overlay an old `base.html.twig`; insert GA4 with `devops webapp <site> ga4`.

## Commands reference

```bash
devops debug http-trace <guild> /api/block
devops debug http-trace <guild> /guild.json
devops debug nginx-top <guild> --since 1h --top 20
devops debug oidc-probe <guild>
devops check apache-workers <guild>
devops check endpoints <guild>
devops logs <guild> structs-webapp-cache 200
devops ssh <guild> -- 'journalctl -u caddy --since -1h --no-pager | tail -100'
```

## Verification

`http-trace` shows every hop answering with sensible TTFB, a repeated
`/api/` request is a `HIT`, `devops check endpoints <site>` is OK, and for
OIDC the token probe prints `PASS`.

## Errors

| Output | Meaning |
|---|---|
| `hop=apache-in-container code=skip note=no_curl_in_container` | image has no curl; judge from the nginx hop and the webapp log |
| `hop=public code=000` from the hub only | your network or DNS; compare with `host-ip` |
| `has no structs-webapp-cache` | the site has no nginx cache (public node, local) |

## See also

- `structs-debug` (router), `structs-debug-postgres`, `structs-debug-indexer`
- The site's own Matrix and structs.app runbooks, if it runs them (`inventory/sites/<site>/runbooks/`)
