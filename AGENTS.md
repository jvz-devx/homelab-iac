# AGENTS.md

This file provides guidance to coding agents working with code in this repository.

## Overview

Fully declarative homelab IaC. Single-node k3s cluster in a Proxmox LXC container, GitOps-managed by FluxCD. Everything from LXC creation to app deployment is defined in code.

## Architecture

```
Proxmox (192.168.1.202)
└── LXC 101 (192.168.1.100) — privileged, Ubuntu 24.04
    └── k3s v1.31.4
        ├── Cilium         (CNI — replaces flannel)
        ├── MetalLB        (LoadBalancer — replaces klipper-lb)
        ├── Traefik        (Ingress — managed by Flux, not k3s built-in)
        ├── cert-manager   (TLS certificates)
        ├── FluxCD         (GitOps reconciliation)
        ├── cloudflared    (Cloudflare Tunnel → jensvanzutphen.com)
        └── NAS storage    (rclone FTP mount → 192.168.1.1)
```

## Commands

```bash
# Enter dev shell (all tools: ansible, flux, kubectl, helm, sops, age, etc.)
nix develop

# Full provisioning from scratch (LXC → k3s → Cilium → Flux)
cd ansible && ansible-playbook site.yml

# Individual stages
ansible-playbook site.yml --tags proxmox   # LXC only
ansible-playbook site.yml --tags k3s       # k3s only
ansible-playbook site.yml --tags flux      # Cilium + Flux only

# Standalone Flux bootstrap (k3s must be running)
ansible-playbook flux-bootstrap.yml

# Cluster operations (run inside `nix develop`)
./scripts/fetch-kubeconfig.sh          # one-time per workstation: pulls k3s kubeconfig to $PWD/kubeconfig
./scripts/reconcile.sh                 # git source + full chain (controllers → configs → apps) in order
./scripts/reconcile.sh apps            # reconcile just one Kustomization
./scripts/reconcile.sh -s              # only re-pull the git source

# Check cluster status
kubectl get nodes
kubectl get pods -A
flux get kustomizations
```

## Key Design Decisions

### Everything is disabled in k3s, managed by Flux

k3s ships with traefik, servicelb (klipper), and flannel. All three are **disabled** via `--disable` flags, and replaced with declarative Flux-managed HelmReleases:

| k3s built-in | Replaced by | Location |
|---|---|---|
| flannel | Cilium | `infrastructure/controllers/cilium/` |
| klipper-lb | MetalLB | `infrastructure/controllers/metallb/` |
| traefik | Traefik (Helm chart) | `infrastructure/controllers/traefik/` |

**Why?** k3s built-ins can't be version-pinned, configured declaratively, or managed via GitOps. The Flux HelmReleases give us version control, reproducible config, and automatic upgrades.

### Cilium is bootstrapped via Helm, then managed by Flux

Cilium is the CNI — pods can't schedule without it. The `flux_bootstrap` Ansible role installs Cilium via Helm before Flux starts. After Flux is running, the HelmRelease in `infrastructure/controllers/cilium/` takes over management.

### Privileged LXC is required

k3s in unprivileged LXC fails due to mount/BPF/cgroup restrictions. The LXC is created privileged with `lxc.apparmor.profile: unconfined`.

## Secrets

Managed by SOPS with Age encryption. Key at `~/.config/sops/age/keys.txt`.

```bash
sops ansible/group_vars/all.sops.yml                    # GitHub PAT, Cloudflare tokens
sops infrastructure/controllers/cloudflared/secret.yaml  # Tunnel token (k8s secret)
sops infrastructure/controllers/nas/secret.yaml          # NAS credentials (k8s secret)
```

**Rules:**
- Never put plaintext secrets in any file
- K8s secrets use `encrypted_regex: ^(data|stringData)$` so only values are encrypted (metadata stays readable)
- Ansible secrets (`*.sops.yml`) are fully encrypted YAML
- Flux decrypts k8s secrets via the `sops-age` secret in `flux-system` namespace

## Flux Dependency Chain

The ordering in `clusters/homelab/` matters:

1. **`infrastructure-controllers`** Kustomization → `./infrastructure/controllers/kustomization.yaml` — installs all HelmReleases (cilium, metallb, traefik, cert-manager, cloudflared, nas). Has healthChecks that wait for CRDs.
2. **`infrastructure-configs`** Kustomization (dependsOn: infrastructure-controllers) → `./infrastructure/configs/kustomization.yaml` — MetalLB IPAddressPool/L2Advertisement, cert-manager ClusterIssuer. Separated because these CRDs don't exist until HelmReleases are ready.
3. **`apps`** Kustomization (dependsOn: infrastructure-controllers) → `./apps/kustomization.yaml` — all user applications.

All Kustomizations reference `GitRepository flux-system` (created by FluxCD bootstrap). You never need to create additional GitRepositories.

## How to Add a New App

1. Create `apps/{app-name}/` with `namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`
2. Create `apps/{app-name}/kustomization.yaml` listing all resource files
3. Ingress uses `ingressClassName: traefik` and annotation `cert-manager.io/cluster-issuer: letsencrypt-production` for TLS
4. Add one line `- {app-name}` to `apps/kustomization.yaml`
5. If pulling from a private registry (e.g., GHCR), add a `ghcr-auth-secret.yaml` with `imagePullSecrets` and reference it in the deployment

## How to Add an Infrastructure Component

1. Create `infrastructure/controllers/{component}/` with `namespace.yaml` + `helmrelease.yaml` (include `HelmRepository` in the same file)
2. HelmRelease versions use `X.Y.x` format (e.g., `"1.16.x"`) to allow automatic patch updates
3. Add to `infrastructure/controllers/kustomization.yaml` (namespace before other resources)
4. If the component creates CRDs that other resources depend on, put those config resources in `infrastructure/configs/kustomization.yaml` instead
5. If other Kustomizations need to wait for this component, add a healthCheck in `clusters/homelab/infrastructure.yaml`

## Variables and Templating

- All Ansible variables live in `ansible/group_vars/all.yml` (single source of truth)
- Ansible secrets in `ansible/group_vars/all.sops.yml`, loaded via `community.sops.sops` lookup
- **K8s manifests are static YAML** — variables from `all.yml` do NOT flow into `infrastructure/` or `apps/` files. Some values (like MetalLB IP range) are intentionally duplicated as hardcoded values in both places.
- The k3s systemd override template (`k3s-override.conf.j2`) completely replaces ExecStart, injecting all flags from `k3s_install_flags` variable

## Flux Reconciliation

When running `flux reconcile`, use a 15-second timeout. After that, check `flux get kustomizations` to see if it's still in progress or stuck on an error. Don't block waiting for full completion — reconciliation can take minutes if pods are slow to start.

```bash
# Run with short timeout, then check status
timeout 15 flux reconcile kustomization apps --with-source || true
flux get kustomizations
```

## Immutable Resource Changes

PersistentVolume specs (and other immutable fields) can't be patched in-place. The Flux Kustomizations have `force: true`, which tells Flux to delete and recreate resources when immutable fields change. No need to manually delete PVs or rename them — just change the manifest and Flux handles it.

Source: [FluxCD Kustomization docs](https://fluxcd.io/flux/components/kustomize/kustomizations/)

## Public DNS, Cloudflare Tunnel, and TLS

Cloudflare, external-dns, cloudflared, Traefik, and cert-manager all touch the
public request path. Debug the whole chain instead of assuming the failing layer.

### Cloudflare Tunnel routing

The tunnel routes `*.jensvanzutphen.com` to Traefik over in-cluster HTTP:

```text
http://traefik.traefik.svc.cluster.local:80
```

For a public tunneled app, the Cloudflare DNS record must point at the tunnel
CNAME, not the home WAN/DDNS hostname:

```text
<host>.jensvanzutphen.com CNAME <tunnel-uuid>.cfargotunnel.com
proxied: true
```

If Cloudflare returns **525 SSL handshake failed**, first check the Cloudflare
DNS target and the tunnel config before changing app containers. In one real
case, `chat.jensvanzutphen.com` still pointed to an old proxied CNAME
(`theflock2.tplinkdns.com`) even though the Kubernetes Ingress was correct.

Useful checks:

```bash
cf dns records list --zone jensvanzutphen.com --name chat.jensvanzutphen.com
kubectl -n cloudflared logs deploy/cloudflared --tail=80
curl -I --max-time 20 https://chat.jensvanzutphen.com
```

### external-dns ownership

external-dns uses a TXT registry with owner id `k3s-homelab`. It will not
blindly take over pre-existing Cloudflare records that lack its ownership TXT
record. This is intentional protection, but it means old manually-created DNS
records may need a one-time adoption step.

The TXT record name in this cluster uses an `a-` prefix. Example:

```text
a-chat.jensvanzutphen.com TXT "heritage=external-dns,external-dns/owner=k3s-homelab,external-dns/resource=ingress/openwebui/openwebui"
```

After adopting a record, wait for the next external-dns poll and confirm:

```bash
kubectl -n external-dns logs deploy/external-dns --since=5m
```

Expected steady-state log:

```text
All records are already up to date
```

external-dns is configured with `policy: upsert-only`: it can create and update
records it owns, but it will not delete records when an Ingress is removed.

### Ingress TLS

Use DNS-01 certificates for public and LAN-facing hostnames under
`jensvanzutphen.com`; do not depend on HTTP-01 being reachable through the
tunnel or LAN-only routes.

For app Ingresses that need public HTTPS, prefer:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-dns01
spec:
  tls:
    - hosts:
        - app.jensvanzutphen.com
      secretName: app-tls
```

Verify cert-manager directly:

```bash
kubectl -n <namespace> get certificate,certificaterequest,order,challenge,secret
kubectl -n <namespace> describe challenge <challenge-name>
dig +short TXT _acme-challenge.<host>.jensvanzutphen.com
```

### End-to-end verification

For public apps, verify all three planes before declaring success:

1. Flux state: `flux get kustomizations`
2. Kubernetes state: `kubectl -n <namespace> get deploy,pods,svc,ingress,certificate`
3. Public edge state: `curl -I --max-time 20 https://<host>.jensvanzutphen.com`

## Phased Deployment (BLOCKING)

**Hard rule: never push a commit that crosses Flux Kustomization boundaries.** The cluster has three layers reconciled in order via `dependsOn`:

1. `infrastructure-controllers` — `infrastructure/controllers/**`
2. `infrastructure-configs` — `infrastructure/configs/**` (depends on 1)
3. `apps` — `apps/**` (depends on 1)

A single commit that touches more than one layer means Flux reconciles the downstream layer before the upstream one has finished. Anything in the downstream layer that references a Secret / CRD / ClusterIssuer / Service created upstream will flap, stall, or deadlock the whole tree.

### Pre-push self-audit (run this literally, every time)

Before any `git commit` that will be pushed, run:

```bash
git diff --cached --name-only
```

Bucket each path into one of the three layers above. **If the diff spans more than one layer, STOP** — split into one commit per layer and push them sequentially, verifying each before the next.

### Triggers that always require a split (non-exhaustive)

- Adding a CRD (ClusterIssuer, IPAddressPool, Certificate, HelmRelease, etc.) **and** a resource that uses it
- Adding a Secret in `cert-manager` / `metallb` / `flux-system` / any controller namespace **and** a config that references it
- Changing an app's `Service.type` or `loadBalancerIP` **and** adding/removing its Ingress in the same diff
- Replacing one networking / storage / ingress mechanism while the old one is still referenced by an app

If you're not sure whether two changes belong in the same commit: they don't. Splitting costs a minute; recovering from a multi-layer stall costs much more.

### Per-layer flow

1. Commit + push one layer
2. `timeout 15 flux reconcile kustomization <kustomization-name> --with-source || true`
3. Verify with `flux get kustomizations` plus a resource-specific check — e.g. `kubectl get clusterissuer <name> -o jsonpath='{.status.conditions[0]}{"\n"}'`, `kubectl -n <ns> get secret <name>`, `kubectl -n <ns> get certificate <name>`
4. Only once the previous layer is healthy, commit + push the next layer

**Do not wave this away as overkill for a small change.** The rule is about the direction of references, not about the size of the diff. Even a one-line ClusterIssuer change paired with an Ingress annotation in the same commit is two layers — split it.

## Cilium Notes

- `hostPort` requires `hostPort.enabled: true` in the Cilium HelmRelease values — it's disabled by default

## Coding Rules

- **Declarative only**: never run imperative `kubectl apply` or `helm install` outside Ansible roles. All k8s resources go in `infrastructure/` or `apps/` and are reconciled by Flux.
- **Single source of truth**: all variables live in `ansible/group_vars/all.yml`. Ansible roles and k8s manifests reference these.
- **Idempotent playbooks**: every Ansible role must be safe to re-run. Use `creates:`, `when:`, and `changed_when:` properly.
- **SOPS for secrets**: use `sops -e -i` to encrypt. Never commit plaintext secrets. `.sops.yaml` has creation rules.
- **No git commit/push without explicit OK**: you may `git add` freely, but never `git commit` or `git push` unless the user has explicitly approved that push. Asking counts as having to wait.
- **Phased pushes (BLOCKING)**: any commit that spans Flux Kustomization layers (`infrastructure/controllers/`, `infrastructure/configs/`, `apps/`) must be split into one commit per layer and pushed sequentially. See "Phased Deployment (BLOCKING)" above for the pre-push self-audit and concrete triggers. Running this self-audit is not optional — do it before every push.
- **Tags for stages**: `proxmox`, `k3s`, `flux` — always preserve the tag structure in `site.yml`.

## Network

| Host | IP | Role |
|---|---|---|
| Proxmox | 192.168.1.202 | Hypervisor |
| k3s-node (LXC 101) | 192.168.1.100 | k3s server |
| NAS | 192.168.1.1 | FTP file storage |
| MetalLB pool | 192.168.1.110–120 | LoadBalancer VIPs |
| Domain | jensvanzutphen.com | Cloudflare Tunnel |
