# Homelab IaC

Fully declarative homelab infrastructure. One command from bare metal to GitOps.

## Architecture

```
Proxmox (192.168.1.202)
└── LXC 101 (192.168.1.100) — privileged, Ubuntu 24.04
    └── k3s v1.31.4
        ├── Cilium       (CNI)
        ├── MetalLB      (LoadBalancer, 192.168.1.110–120)
        ├── Traefik      (Ingress)
        ├── cert-manager (TLS)
        ├── FluxCD       (GitOps)
        ├── cloudflared  (Tunnel → jensvanzutphen.com)
        └── NAS storage  (rclone FTP → 192.168.1.1)
```

All k3s built-ins (traefik, servicelb, flannel) are disabled and replaced with declarative Flux-managed HelmReleases.

## Quick Start

```bash
nix develop
cd ansible
ansible-playbook site.yml
```

## Staged Provisioning

```bash
ansible-playbook site.yml --tags proxmox   # LXC only
ansible-playbook site.yml --tags k3s       # k3s only
ansible-playbook site.yml --tags flux      # Cilium + Flux only
```

## Disaster Recovery

```bash
ansible-playbook site.yml   # Rebuilds everything; Flux reconciles workloads from Git
```

## Secrets

```bash
sops ansible/group_vars/all.sops.yml        # GitHub PAT, Cloudflare tokens
sops infrastructure/cloudflared/secret.yaml  # Tunnel token
sops infrastructure/nas/secret.yaml          # NAS credentials
```
