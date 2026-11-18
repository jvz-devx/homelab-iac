# CLIProxyAPI

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) pools Jens's Codex
subscriptions behind one endpoint. Codex clients (T3 Code on the Mac) talk to
the proxy, and the proxy picks the account. When an account hits its usage
limit, the next request goes to the next account.

## Access

The Service is exposed to the tailnet as `cliproxyapi` by the Tailscale
operator: `http://cliproxyapi:8317`. There is no Ingress and no Cloudflare
route. Keep it that way: the pod holds OAuth tokens for the accounts.

Clients send the API key from `access.api-keys`. The management API and the
web panel at `/management.html` need `management.secret-key`. Both keys are in
`secret.yaml`:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d apps/hetzner/cliproxyapi/secret.yaml
```

The homelab cluster reaches the same device through an egress Service
(`apps/startpage/cliproxyapi-egress.yaml`), for the startpage's codex pool
panel.

## Routing

`secret.yaml` holds the whole `config.yaml`, mounted read-only.

- `routing.strategy: fill-first` uses one account until it runs out. The
  `priority` field in each credential file decides the order; higher wins.
- `routing.session-affinity` keeps a conversation on one account so the prompt
  cache is reused. A usage limit or auth error moves it to the next account.

## Accounts

OAuth credentials live in the `cliproxyapi-auth` PVC (`local-path-retain`),
mounted at `/root/.cli-proxy-api`. They are not in git. Deleting the PV means
logging in to every account again.

To add an account, open the web panel, or start a login through the
management API and finish it in a browser:

```bash
curl -H "Authorization: Bearer $MGMT_KEY" http://cliproxyapi:8317/v0/management/codex-auth-url
```

The browser ends on `http://localhost:1455/...`, which does not load on a
machine that is not the pod. Pass that final URL to the proxy:

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"provider":"codex","redirect_url":"<final URL>"}' \
  http://cliproxyapi:8317/v0/management/oauth-callback
```

## Upgrades

A weekly scheduled agent in T3 Code on workstation-01 (Monday 06:00) runs
`scripts/update-cliproxyapi.sh`. The proxy imitates the official Codex client,
so it goes stale if it is not updated.

The script picks the newest 8.x release that is at least three days old
(`SOAK_DAYS`) and on Docker Hub for amd64. If that is newer than the pin, it
rewrites the `image:` line in `deployment.yaml` (tag and digest), commits,
pushes to `origin main`, asks Flux to reconcile and waits for the rollout. It
never downgrades, and a new major version waits for a manual update.

After the rollout it checks that the pod runs the new pin, that the proxy
still has all its accounts with none disabled, and that `/v1/models` answers.
An account at its usage limit is not a failure. If a check fails, the script
reverts the commit, rolls back the same way and exits non-zero. Its last
output line starts with `RESULT:`.

```bash
scripts/update-cliproxyapi.sh --dry-run   # changes nothing, still runs the checks
scripts/update-cliproxyapi.sh
```

It needs `ssh hetzner`, the management key
(`CLIPROXYAPI_MANAGEMENT_KEY`, or the file `/run/secrets/cliproxyapi_management_key`)
and the API key (`CLIPROXYAPI_API_KEY`). The config uses the v8 layout
(`config-version: 8`).
