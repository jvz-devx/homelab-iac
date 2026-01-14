# CLAUDE.md

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
flux reconcile kustomization infrastructure
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
| flannel | Cilium | `infrastructure/cilium/` |
| klipper-lb | MetalLB | `infrastructure/metallb/` |
| traefik | Traefik (Helm chart) | `infrastructure/traefik/` |

**Why?** k3s built-ins can't be version-pinned, configured declaratively, or managed via GitOps. The Flux HelmReleases give us version control, reproducible config, and automatic upgrades.

### Cilium is bootstrapped via Helm, then managed by Flux

Cilium is the CNI — pods can't schedule without it. The `flux_bootstrap` Ansible role installs Cilium via Helm before Flux starts. After Flux is running, the HelmRelease in `infrastructure/cilium/` takes over management.

### Privileged LXC is required

k3s in unprivileged LXC fails due to mount/BPF/cgroup restrictions. The LXC is created privileged with `lxc.apparmor.profile: unconfined`.

## Secrets

Managed by SOPS with Age encryption. Key at `~/.config/sops/age/keys.txt`.

```bash
sops ansible/group_vars/all.sops.yml        # GitHub PAT, Cloudflare tokens
sops infrastructure/cloudflared/secret.yaml  # Tunnel token (k8s secret)
sops infrastructure/nas/secret.yaml          # NAS credentials (k8s secret)
```

**Rules:**
- Never put plaintext secrets in any file
- K8s secrets use `encrypted_regex: ^(data|stringData)$` so only values are encrypted
- Ansible secrets are fully encrypted YAML
- Flux decrypts k8s secrets via the `sops-age` secret in `flux-system` namespace

## File Layout

```
ansible/
├── site.yml                          # 4-stage pipeline (proxmox → k3s → flux)
├── flux-bootstrap.yml                # Standalone Flux bootstrap
├── inventory/hosts.yml               # Proxmox host + k3s node
├── group_vars/
│   ├── all.yml                       # ALL config — single source of truth
│   └── all.sops.yml                  # Encrypted secrets
└── roles/
    ├── proxmox_lxc/                  # Creates LXC on Proxmox (idempotent)
    ├── k3s_prereqs/                  # OS packages, sysctl, kernel modules
    ├── k3s_server/                   # k3s install + templated systemd override
    └── flux_bootstrap/               # Cilium bootstrap + Flux bootstrap

clusters/homelab/
├── infrastructure.yaml               # Flux Kustomization → infrastructure/
└── apps.yaml                         # Flux Kustomization → apps/

infrastructure/                       # All managed by Flux after bootstrap
├── cilium/                           # CNI
├── metallb/                          # LoadBalancer + IP pool config
├── traefik/                          # Ingress controller
├── cert-manager/                     # TLS certificate automation
├── cloudflared/                      # Cloudflare Tunnel
└── nas/                              # NAS FTP mount via rclone

apps/                                 # Application deployments (add here)
```

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
