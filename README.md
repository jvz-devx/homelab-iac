# Homelab IaC

Fully declarative homelab infrastructure. One command from bare metal to GitOps.

## Architecture

```
Proxmox (192.168.1.202)
└── LXC 101 (192.168.1.100) — privileged, Ubuntu 24.04
    └── k3s v1.31.4
        ├── Cilium (CNI, replaces flannel)
        ├── FluxCD (GitOps)
        ├── cert-manager
        ├── ingress-nginx (replaces traefik)
        ├── cloudflared (Cloudflare Tunnel → jensvanzutphen.com)
        └── NAS storage (FTP mount via rclone → 192.168.1.1)
```

## Prerequisites

- Nix with flakes enabled
- Age key at `~/.config/sops/age/keys.txt`
- SSH access to Proxmox host (192.168.1.202)
- GitHub PAT with `repo` scope in `ansible/group_vars/all.sops.yml`

## Quick Start

```bash
# Enter dev shell (provides ansible, flux, kubectl, helm, sops, age, etc.)
nix develop

# Full provisioning: Proxmox LXC → k3s → Cilium → FluxCD
cd ansible
ansible-playbook site.yml
```

## Staged Provisioning

```bash
# Stage 1: Create LXC on Proxmox only
ansible-playbook site.yml --tags proxmox

# Stage 2+3: Install k3s only (LXC must exist)
ansible-playbook site.yml --tags k3s

# Stage 4: Bootstrap Cilium + FluxCD only (k3s must be running)
ansible-playbook site.yml --tags flux
# Or standalone:
ansible-playbook flux-bootstrap.yml
```

## Disaster Recovery

1. `ansible-playbook site.yml` — recreates everything from scratch
2. FluxCD automatically reconciles all workloads from Git

## Secrets

Encrypted with SOPS/Age. To edit:

```bash
sops ansible/group_vars/all.sops.yml        # Ansible secrets
sops infrastructure/cloudflared/secret.yaml  # K8s secrets
sops infrastructure/nas/secret.yaml          # NAS credentials
```

## Repository Structure

```
ansible/
├── site.yml                    # Full provisioning playbook
├── flux-bootstrap.yml          # Standalone Flux bootstrap
├── inventory/hosts.yml         # Proxmox + k3s hosts
├── group_vars/
│   ├── all.yml                 # All variables (declarative config)
│   └── all.sops.yml            # Encrypted secrets
└── roles/
    ├── proxmox_lxc/            # LXC creation on Proxmox
    ├── k3s_prereqs/            # OS setup for k3s
    ├── k3s_server/             # k3s install + systemd override
    └── flux_bootstrap/         # Cilium + FluxCD bootstrap
clusters/homelab/               # Flux entrypoints
infrastructure/                 # Declarative k8s infra
├── cilium/                     # CNI (managed by Flux after bootstrap)
├── cert-manager/               # TLS certificates
├── ingress-nginx/              # Ingress controller
├── cloudflared/                # Cloudflare Tunnel
└── nas/                        # NAS FTP mount via rclone
apps/                           # Application deployments
```
