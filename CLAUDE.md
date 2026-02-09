# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

# Force Flux reconciliation
flux reconcile kustomization infrastructure-controllers
flux reconcile kustomization infrastructure-configs
flux reconcile kustomization apps

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

## Phased Deployment

When making changes that touch infrastructure dependencies (Cilium, NAS, etc.), deploy in phases to avoid cascading failures:

1. **Comment out** dependent resources (apps, NAS) in their kustomization files
2. **Push + reconcile** the infrastructure change (e.g., Cilium config)
3. **Verify** the infrastructure change is healthy (`flux get kustomizations`, `kubectl get pods`)
4. **Re-enable** dependencies one layer at a time, pushing + reconciling after each
5. **Verify** each layer before enabling the next

Never push everything at once — if something breaks mid-chain, the entire dependency tree stalls and debugging becomes harder.

## Cilium Notes

- `hostPort` requires `hostPort.enabled: true` in the Cilium HelmRelease values — it's disabled by default

## Coding Rules

- **Declarative only**: never run imperative `kubectl apply` or `helm install` outside Ansible roles. All k8s resources go in `infrastructure/` or `apps/` and are reconciled by Flux.
- **Single source of truth**: all variables live in `ansible/group_vars/all.yml`. Ansible roles and k8s manifests reference these.
- **Idempotent playbooks**: every Ansible role must be safe to re-run. Use `creates:`, `when:`, and `changed_when:` properly.
- **SOPS for secrets**: use `sops -e -i` to encrypt. Never commit plaintext secrets. `.sops.yaml` has creation rules.
- **No git commit/push**: you may `git add` but never commit or push.
- **Tags for stages**: `proxmox`, `k3s`, `flux` — always preserve the tag structure in `site.yml`.

## Network

| Host | IP | Role |
|---|---|---|
| Proxmox | 192.168.1.202 | Hypervisor |
| k3s-node (LXC 101) | 192.168.1.100 | k3s server |
| NAS | 192.168.1.1 | FTP file storage |
| MetalLB pool | 192.168.1.110–120 | LoadBalancer VIPs |
| Domain | jensvanzutphen.com | Cloudflare Tunnel |
