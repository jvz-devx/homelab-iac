# Strikers

Private browser multiplayer at https://strikers.jensvanzutphen.com.
Source: https://github.com/jvz-devx/strikers-wasm. The container image is private
and digest-pinned. The server does not render gameplay or require a GPU.

## Persistence and startup

One replica owns `strikers-data`. `Recreate` and the application's exclusive data
lock prevent concurrent SQLite/save writers. The PVC and namespace have pruning
disabled so removing the app manifest does not silently erase progression.

The PVC's `strikers/` directory contains the administrator database, lobby saves,
installed content and `source/strikers.iso`. The application owns this subdirectory
as UID 10001; it does not need to chmod the root-owned volume mount. Its source
directory is mounted at `/games` read-only.
`STRIKERS_ISO_PATH=/games/strikers.iso` automatically installs a configured image
on a fresh data directory and reuses an existing valid installation on restart.
The original image is not exposed by the asset API.

An empty PVC waits in `wait-for-seed`. Restore a consistent stopped-server backup
and the owned source image through the private Kubernetes connection. Verify all
copied files before creating `/data/.seed-complete`; only then does the app start.
Run copying and verification as UID/GID 10001. Never restore over an active server.

Back up the complete PVC while the server is stopped, including SQLite, saves,
content and source image. Application/image updates retain the same PVC.

## Access

Traefik, cert-manager DNS-01 and external-dns use the existing homelab Cloudflare
tunnel. Preserve the application's cross-origin-isolation headers and WebSocket
forwarding. Use the HTTPS origin exactly as configured.

Large initial uploads should use the private connection, not the Cloudflare HTTP
upload path. Administrator authentication and invitations still protect content;
there is no public registration or downloadable original disc endpoint.

## WebTransport relay

Game frames can travel as WebTransport datagrams (UDP/QUIC) next to the
WebSocket; see `docs/webtransport.md` in the application repository. Cloudflare
Tunnel carries no UDP, so browsers connect to `https://91.98.43.250:4433/wt`,
the Hetzner node's public address:

```text
browser -> Hetzner UDP 4433 (hcloud firewall 10908357)
        -> strikers-relay pod, hostNetwork, `strikers-server --udp-relay`
        -> Tailscale: strikers-wt-homelab (operator proxy for strikers-webtransport)
        -> strikers pod UDP 4433
```

The relay only moves UDP packets; TLS ends in the strikers pod with a
self-signed certificate whose hash the browser receives over the WebSocket, so
there is no certificate to manage. If WebTransport fails, browsers keep using
the WebSocket. To turn the path off, remove `strikers-relay` from
`apps/hetzner/kustomization.yaml` or unset `STRIKERS_WEBTRANSPORT_BIND`.
