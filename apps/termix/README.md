# Termix

Termix is deployed on the homelab k3s cluster as a single-replica workload with persistent storage and a fixed MetalLB address.

## What gets deployed

- Namespace: `termix`
- Deployment: `ghcr.io/lukegus/termix:latest`
- PersistentVolumeClaim: `termix-data` (`5Gi`, `ReadWriteOnce`)
- Service: `LoadBalancer` on `192.168.1.111`
- Local URL: `http://192.168.1.111`

## Why LoadBalancer instead of Ingress

Termix is intended as a LAN-first jump host / SSH management UI. Exposing it on a dedicated local IP keeps it simple and avoids mixing the first boot flow with public ingress and TLS.

## Runtime config

The deployment intentionally keeps the setup minimal:

- `PORT=4090`
- `DATA_DIR=/app/data`
- `ENABLE_GUACAMOLE=false`
- `PUID=1000`
- `PGID=1000`

Remote desktop support (`guacd`) is disabled for now because the immediate goal is SSH host management from the LAN.

## Bootstrap notes

After Flux deploys the app:

1. Open `http://192.168.1.111`
2. Create the initial Termix user
3. Add or generate an SSH credential inside Termix
4. Register LAN hosts by local IP (for example `192.168.1.201`, `192.168.1.202`, `192.168.1.100`)
5. If you generate a dedicated Termix keypair, distribute the public key to the target hosts before assigning the credential to those hosts

## Suggested initial hosts

- `192.168.1.201` — Proxmox node1
- `192.168.1.202` — Proxmox node2
- `192.168.1.100` — k3s-node LXC

Additional hosts can be added later once their SSH access is standardized.
