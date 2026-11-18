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

The image is pinned by tag and digest in `deployment.yaml`. The config uses
the v8 layout (`config-version: 8`).
