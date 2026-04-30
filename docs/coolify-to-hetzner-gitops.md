# Coolify To Hetzner GitOps Migration

This document inventories the former Docker/Coolify workloads on `coolify-ubuntu-4gb-fsn1-1` and records how they were reproduced declaratively in the Hetzner Kubernetes GitOps cluster.

Inventory date: 2026-04-30
Decommission date: 2026-04-30

## Source Host

The source host was verified through the Hetzner Cloud API and SSH during migration. It has now been decommissioned.

| Field | Value |
|---|---|
| Hetzner server ID | `111924551` |
| Name | `coolify-ubuntu-4gb-fsn1-1` |
| Status | deleted |
| Server type | `cpx32` |
| Location | `fsn1` |
| Datacenter | `fsn1-dc14` |
| OS image | Debian 13 |
| Public IPv4 | `159.69.186.8` |
| Public IPv6 | `2a01:4f8:c014:faf4::/64` |
| Hetzner private networks | none |
| Hetzner volumes | none |
| Hetzner firewalls | none attached |

The host had no Hetzner private network or attached Hetzner volumes. Persistent data was in Docker named volumes and `/data/coolify/...` bind mounts. The Coolify VM was deleted after the selected workloads and data were migrated or intentionally discarded.

Removed old Cloudflare records that pointed at `159.69.186.8`:

- `bedrock.tunetap.xyz`
- `minecraft.tunetap.xyz`
- `*.tunetap.xyz`
- `jensvanzutphen.com`

## High-Level Topology

```text
Internet
  -> coolify-proxy, Traefik on :80/:443/:443-udp/:8080
    -> public app containers on Docker network coolify, 10.0.1.0/24
      -> app-specific PostgreSQL and Redis containers where needed
      -> Docker named volumes or /data/coolify bind mounts

Coolify control plane
  -> coolify, coolify-realtime, coolify-db, coolify-redis, coolify-sentinel
  -> Docker socket and /data/coolify storage
```

For GitOps, reproduce the app topology, not the Coolify control plane. The Coolify system containers are migration tooling/source-of-truth history only unless we intentionally want to keep running Coolify.

## Container Inventory

### Public Applications

| App | Coolify project | Container | Image | Status | Public domain(s) | App port | Storage | Dependencies | GitOps target |
|---|---|---|---|---|---|---:|---|---|---|
| Open WebUI | `my-first-project` | `wwkgscg0cg80skks8gk44cws-193442560243` | `ghcr.io/open-webui/open-webui:main` | old Coolify copy discarded; active `chat.jensvanzutphen.com` backend migrated to Hetzner | `chat.tunetap.xyz` | 1234 | old Coolify `/app/backend/data` discarded; homelab Open WebUI data restored to Hetzner PVC | OpenAI-compatible API via env | `apps/hetzner/openwebui` |
| Prowlarr | `prowlarr` | `c4c4oowosg04okgkgkgk4c88-092609951372` | `lscr.io/linuxserver/prowlarr:latest` | migrated; Coolify container removed | `prowlarr.tunetap.xyz` | 9696 | Hetzner PVC `prowlarr-config -> /config`; old Coolify bind dir left as recovery trail | restored `/config` including `prowlarr.db` | `apps/hetzner/prowlarr` |
| Tunetap app | `tunetap` | `mwkcggs4c4wsgcwoggogwkk4-145216530096` | `ghcr.io/jvz-devx/coolify-tunetap-app@sha256:74eff492e808ddd6e26ee83723c93ce686f992a7b74ef21d9ec2c5d8568fae12` | migrated; Coolify container removed | `app.tunetap.xyz` | 3000 | Hetzner PVC `tunetap-data -> /app/data` | SQLite `DATABASE_URL=file:/app/data/database.db`; Puppeteer env retained | `apps/hetzner/tunetap-app` |
| CV web | `tunetap` | `sw88os0occgccw0g88sgk4sk-111703755342` | `ghcr.io/jvz-devx/coolify-cv-web@sha256:62d9688c2b471b931770e0f8ab6d7f8058e1589e6beace9405a3a6bda76310bb` | migrated; Coolify container removed | `cv.tunetap.xyz`, `cv.jensvanzutphen.com` | 3000 | none | none seen | `apps/hetzner/cv-web` |
| Dart Bingo | `dartbingo` | `nc044040wwks0gkg8ogwwc0c-154334423467` | `ghcr.io/jvz-devx/coolify-dartbingo@sha256:782a9e2582d3197b337393ab20e2508c38d00c4dd18391152e86a91b8f54903b` | migrated; Coolify container removed | `dart.tunetap.xyz` | 3000 | none | none seen | `apps/hetzner/dartbingo` |
| Sweet Heist | `sweet-heist` | `a0kkgsok4go8g0c4g8gsck0k-203517326375` | `a0kkgsok4go8g0c4g8gsck0k:cf7399ac0549150c3a9c6523a015366509cdcbf1` | discarded with Coolify VM | `a0kkgsok4go8g0c4g8gsck0k.tunetap.xyz` | 3000 | none | none seen | not migrated |
| Klavier SvelteKit | `klavier-dev` | `xkcskk4ok44s40g8wc0800go-153431237329` | `ghcr.io/jvz-devx/coolify-klavier-sveltekit@sha256:d7351f92ce5636f74425d25b6438a1782c1fe84af62e7517a835090844d01832` | migrated; Coolify container removed | `klavier-dev.tunetap.xyz` | 3000 | none | PostgreSQL, Redis, Cloudflare R2, GitHub OAuth, Better Auth | `apps/hetzner/klavier-dev` |
| Klavier WebSocket server | `klavier-dev` | `po4k048owkwcgwoso0owc8cg-153431205726` | `ghcr.io/jvz-devx/coolify-klavier-websocket@sha256:ffaf94dad0901a8b27805a48c4aa7471fb88919faf05d3dd3c7f36aad380447c` | migrated; Coolify container removed | `po4k048owkwcgwoso0owc8cg.tunetap.xyz` | 3001 | none | PostgreSQL, Redis | `apps/hetzner/klavier-dev` |

### Application Databases

| Database | Coolify project | Container | Image | Status | Port | Storage | Used by | GitOps target |
|---|---|---|---|---|---:|---|---|---|
| PostgreSQL | `klavier-dev` | `rwgkogsg8o0c804o0ssosw8w` | `postgres:17-alpine` | migrated; Coolify container removed | 5432 | Hetzner PVC `postgres-data`; old Docker volume left as recovery trail | Klavier SvelteKit and WebSocket server | `apps/hetzner/klavier-dev/postgres.yaml` |
| Redis | `klavier-dev` | `fs0ccwkcwwg04kg4wkgos04o` | `redis:7.2` | migrated; Coolify container removed | 6379 | Hetzner PVC `redis-data`; old Docker volume left as recovery trail | Klavier SvelteKit and WebSocket server | `apps/hetzner/klavier-dev/redis.yaml` |

### Coolify Control Plane

These were deleted with the Coolify VM after migration.

| Component | Container | Image | Status | Ports | Storage / special access |
|---|---|---|---|---|---|
| Coolify app | `coolify` | `ghcr.io/coollabsio/coolify:4.0.0-beta.460` | deleted | host `8000 -> 8080`; container 8000/8443/9000 | discarded |
| Coolify realtime | `coolify-realtime` | `ghcr.io/coollabsio/coolify-realtime:1.0.10` | deleted | host `6001-6002` | discarded |
| Coolify PostgreSQL | `coolify-db` | `postgres:15-alpine` | deleted | 5432 internal | discarded |
| Coolify Redis | `coolify-redis` | `redis:7-alpine` | deleted | 6379 internal | discarded |
| Coolify proxy | `coolify-proxy` | `traefik:latest` | deleted | host 80, 443/tcp, 443/udp, 8080 | discarded |
| Coolify sentinel | `coolify-sentinel` | `ghcr.io/coollabsio/sentinel:0.0.21` | deleted | none public | discarded |

## Docker Networks

| Network | Driver | Subnet | Gateway | Containers | Kubernetes replacement |
|---|---|---|---|---:|---|
| `coolify` | bridge | `10.0.1.0/24` | `10.0.1.1` | 14 | Kubernetes Services and namespace DNS |
| `bridge` | bridge | `10.0.0.0/24` | `10.0.0.1` | 1 | Not needed for migrated apps |
| `host` | host | n/a | n/a | 0 | Avoid unless explicitly required |
| `none` | null | n/a | n/a | 0 | Not needed |

## Persistent Data

| Current source | Type | Mounted into | Purpose | Kubernetes target |
|---|---|---|---|---|
| `/data/coolify/applications/wwkgscg0cg80skks8gk44cws` | host bind | Open WebUI `/app/backend/data` | Open WebUI data | PVC restored from tar/rsync |
| `/data/coolify/applications/c4c4oowosg04okgkgkgk4c88` | host bind | Prowlarr `/config` | Prowlarr config/database | PVC restored from tar/rsync |
| `postgres-data-rwgkogsg8o0c804o0ssosw8w` | Docker volume | PostgreSQL `/var/lib/postgresql/data` | Klavier database | Prefer `pg_dump` restore into new Postgres PVC |
| `redis-data-fs0ccwkcwwg04kg4wkgos04o` | Docker volume | Redis `/data` | Klavier Redis state | PVC restore if the data is important; otherwise start fresh |
| `coolify-db` | Docker volume | Coolify DB | Coolify control-plane metadata | Archive only unless migrating Coolify |
| `coolify-redis` | Docker volume | Coolify Redis | Coolify control-plane cache | Do not migrate |
| `open-webui` | Docker volume | not mounted by current Open WebUI container | likely stale | Verify before deleting |
| `wwkgscg0cg80skks8gk44cws-open-webui` | Docker volume | not mounted by current Open WebUI container | likely stale | Verify before deleting |

## Secret And Config Keys

Values were not copied. These are key names discovered from sanitized container environment.

### Klavier SvelteKit

Secret-like keys:

```text
BETTER_AUTH_SECRET
CLOUDFLARE_ACCOUNT_ID
DATABASE_URL
GITHUB_CLIENT_ID
GITHUB_CLIENT_SECRET
R2_ACCESS_KEY_ID
R2_BUCKET_NAME
R2_ENDPOINT
R2_SECRET_ACCESS_KEY
REDIS_URL
```

Non-secret/runtime keys:

```text
HOST
NODE_ENV
ORIGIN
PORT
PUBLIC_WS_URL
SOURCE_COMMIT
```

### Klavier WebSocket Server

Secret-like keys:

```text
DATABASE_URL
REDIS_URL
```

Non-secret/runtime keys:

```text
DEBUG
HOST
PORT
RUST_BACKTRACE
SOURCE_COMMIT
```

### Klavier PostgreSQL

Secret-like keys:

```text
POSTGRES_DB
POSTGRES_PASSWORD
POSTGRES_USER
```

### Klavier Redis

Secret-like keys:

```text
REDIS_PASSWORD
REDIS_USERNAME
```

### Open WebUI

Secret-like keys:

```text
OLLAMA_BASE_URL
OPENAI_API_BASE_URL
OPENAI_API_KEY
WEBUI_SECRET_KEY
```

Model/config keys:

```text
RAG_EMBEDDING_MODEL
RAG_RERANKING_MODEL
TIKTOKEN_ENCODING_NAME
WHISPER_MODEL
```

### Other Public Apps

The CV, Dart Bingo, Sweet Heist, and Prowlarr containers mostly expose Coolify metadata plus `HOST`/`PORT`/runtime keys. Prowlarr's sensitive app config is likely inside its `/config` mount, not in environment variables.

## GitOps Reproduction Plan

Use one directory per app group under `apps/hetzner/`.

```text
apps/hetzner/<app>/
  namespace.yaml
  secret.yaml              # SOPS encrypted if needed
  pvc.yaml                 # only if persistent data exists
  deployment.yaml          # stateless app containers
  statefulset.yaml         # databases or durable single-writer services
  service.yaml
  ingress.yaml             # public HTTP(S)
  kustomization.yaml
```

Then add the app directory to `apps/hetzner/kustomization.yaml`.

## Recommended App Groups

### `apps/hetzner/klavier-dev`

One namespace containing:

- PostgreSQL 17 StatefulSet + PVC, or a later CloudNativePG cluster.
- Redis StatefulSet/Deployment + PVC.
- SvelteKit Deployment on port 3000.
- WebSocket Deployment on port 3001.
- Services:
  - `postgres`
  - `redis`
  - `sveltekit`
  - `websocket`
- Ingresses:
  - `klavier-dev.tunetap.xyz -> sveltekit:3000`
  - `po4k048owkwcgwoso0owc8cg.tunetap.xyz -> websocket:3001`, or replace with a better stable hostname.
- SOPS Secret containing auth, GitHub OAuth, R2, database, and Redis keys.

Important: the WebSocket container is currently restart-looping with exit code 101. Fix or intentionally preserve the current image only after checking logs.

### `apps/hetzner/openwebui`

This is the active backend for `chat.jensvanzutphen.com`.

- Deployment using `ghcr.io/open-webui/open-webui:v0.9.2`.
- PVC `openwebui-data` mounted at `/app/backend/data`.
- Data was migrated from homelab Open WebUI as a full tar archive of `/app/backend/data`, including `webui.db`, WAL files, uploads, vector DB, and model cache.
- Homelab keeps its old `openwebui-data` PVC as a fallback copy, but its Open WebUI Deployment is scaled to `0`.
- Homelab `openwebui` Service is now a Tailscale ExternalName to `openwebui-hetzner.zebu-dorian.ts.net`, so the existing `chat.jensvanzutphen.com` Ingress, TLS secret, DNS, and OAuth redirect URI are unchanged.
- Chat and image generation still use CLIProxyAPI through `cliproxyapi.remote-homelab.svc.cluster.local:8317`.

### `apps/hetzner/prowlarr`

- Deployment using `lscr.io/linuxserver/prowlarr:latest`.
- PVC `prowlarr-config` mounted at `/config`.
- Data was migrated from Coolify bind mount `/data/coolify/applications/c4c4oowosg04okgkgkgk4c88`, including `prowlarr.db`, `logs.db`, `config.xml`, backups, and definitions.
- Service port 9696.
- Homelab ingress route for `prowlarr.tunetap.xyz` uses the Tailscale proxy `prowlarr-hetzner.zebu-dorian.ts.net`.
- Treat `/config` as sensitive because it may include API keys and indexer credentials.

### `apps/hetzner/tunetap-app`

- Deployment from the committed Coolify container image:
  `ghcr.io/jvz-devx/coolify-tunetap-app@sha256:74eff492e808ddd6e26ee83723c93ce686f992a7b74ef21d9ec2c5d8568fae12`.
- The committed image includes the original `/app/data/database.db` snapshot.
- Init container seeds `tunetap-data` PVC on first boot if `/data/database.db` does not exist.
- Main container mounts `tunetap-data` at `/app/data`.
- Service port 3000.
- Homelab ingress route for `app.tunetap.xyz` uses the Tailscale proxy
  `tunetap-app-hetzner.zebu-dorian.ts.net`.
- `DATABASE_URL=file:/app/data/database.db`.
- Confirm whether Puppeteer/Chrome is truly required because the current env includes Puppeteer settings.

### `apps/hetzner/cv-web`

- Deployment from the current generated image or rebuild from source.
- Service port 3000.
- Ingress hosts:
  - `cv.tunetap.xyz`
  - `cv.jensvanzutphen.com`

### `apps/hetzner/dartbingo`

- Deployment from the current generated image or rebuild from source.
- Service port 3000.
- Ingress for `dart.tunetap.xyz`.

### `apps/hetzner/sweet-heist`

- Deployment from the current generated image or rebuild from source.
- Service port 3000.
- Ingress for `a0kkgsok4go8g0c4g8gsck0k.tunetap.xyz`, or choose a stable friendly hostname before migrating.

## Image Strategy

Coolify generated local Docker images such as:

```text
xkcskk4ok44s40g8wc0800go:<git-sha>
po4k048owkwcgwoso0owc8cg:<git-sha>
sw88os0occgccw0g88sgk4sk:<git-sha>
```

Kubernetes cannot pull those from the old VM unless they are pushed to a registry. For each generated app image, choose one:

1. Rebuild from the original Git repo in CI and push to GHCR.
2. Export the existing image, import it into a registry, and pin by digest.
3. Recreate the app from source with a normal Dockerfile and Flux image automation later.

Do not reference the old local image names directly in Kubernetes manifests unless a registry mirror is created first.

## Data Migration Commands

Run backups from the Coolify host before cutting over.

PostgreSQL:

```bash
docker exec rwgkogsg8o0c804o0ssosw8w pg_dumpall -U "$POSTGRES_USER" > klavier-postgres.dump.sql
```

If `$POSTGRES_USER` is not available in the shell, read it from the container environment without printing passwords:

```bash
docker exec rwgkogsg8o0c804o0ssosw8w printenv POSTGRES_USER
```

Bind-mounted app data:

```bash
tar -C /data/coolify/applications -czf openwebui-data.tgz wwkgscg0cg80skks8gk44cws
tar -C /data/coolify/applications -czf prowlarr-config.tgz c4c4oowosg04okgkgkgk4c88
```

Redis, only if required:

```bash
docker exec fs0ccwkcwwg04kg4wkgos04o redis-cli SAVE
tar -C /var/lib/docker/volumes -czf klavier-redis-data.tgz redis-data-fs0ccwkcwwg04kg4wkgos04o
```

## Migration Order

1. Decide which apps are still wanted. Open WebUI may already be superseded by the existing GitOps deployment.
2. For each app image, rebuild/push to GHCR or export/import the current image.
3. Create SOPS Secrets using the discovered key names, never plaintext files.
4. Create PVCs and restore data for Prowlarr, Open WebUI, PostgreSQL, and Redis.
5. Deploy `klavier-dev` databases first.
6. Deploy `klavier-dev` app and WebSocket server; fix the WebSocket restart loop before DNS cutover.
7. Deploy the simpler stateless apps: CV, Dart Bingo, Sweet Heist, Tunetap.
8. Add Ingresses and DNS records.
9. Smoke test each service on the Kubernetes URL.
10. Stop the matching Coolify container and verify traffic still works.
11. Delete the Coolify VM once migrated workloads are healthy and discarded workloads are confirmed unneeded.

## Runtime Checks After Each App

```bash
kubectl -n <namespace> get deploy,statefulset,pod,svc,ingress,pvc
kubectl -n <namespace> logs deploy/<app> --tail=100
curl -I https://<domain>
```

For stateful apps:

```bash
kubectl -n <namespace> rollout restart deploy/<app>
kubectl -n <namespace> get pod,pvc
curl -I https://<domain>
```

## Final Decommission Result

- All Docker containers on `coolify-ubuntu-4gb-fsn1-1` were removed.
- Hetzner server `111924551` was deleted.
- Hetzner Cloud now only lists the GitOps k3s node `hetzner-k3s-1`.
- Cloudflare no longer has records pointing at `159.69.186.8` in `tunetap.xyz` or `jensvanzutphen.com`.
- Local migration archives remain under repo-local `.tmp/migration/` and are intentionally untracked.

## Raw Inventory Location

The redacted inventory used for this document was generated locally at:

```text
/tmp/coolify-inventory.uhJGV1
```

It includes:

```text
inventory.json
networks.json
volumes.json
compose-files.txt
```

Do not commit raw inventory files without reviewing them first. Even redacted metadata can reveal internal URLs, project names, and operational details.
