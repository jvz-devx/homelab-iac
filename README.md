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
        ├── Tailscale    (cross-cluster service access)
        └── NAS storage  (rclone FTP → 192.168.1.1)
```

All k3s built-ins (traefik, servicelb, flannel) are disabled and replaced with declarative Flux-managed HelmReleases.

The repo also contains a second independent k3s cluster on Hetzner. The clusters
share GitOps and SOPS trust, but they are separate Kubernetes control planes.
Cross-cluster traffic uses host-level Tailscale subnet routers plus the
Tailscale Kubernetes Operator for selected stable Services. See
[`docs/multicluster.md`](docs/multicluster.md) and
[`docs/tailscale-routing.md`](docs/tailscale-routing.md).

## Prerequisites

- [Nix](https://nixos.org/) — `nix develop` provides all CLI tools (ansible, kubectl, flux, helm, sops, age)
- Proxmox host with API access
- [Age](https://github.com/FiloSottile/age) key at `~/.config/sops/age/keys.txt` for SOPS decryption
- GitHub PAT with repo scope (stored in `ansible/group_vars/all.sops.yml`)
- SOPS-encrypted secrets populated (see [Secrets](#secrets))

## Project Structure

```
ansible/                  # Provisioning playbooks and roles
├── roles/
│   ├── proxmox_lxc/      # LXC container creation
│   ├── k3s_prereqs/      # Node prep (packages, kernel modules)
│   ├── k3s_install/      # k3s installation and config
│   └── flux_bootstrap/   # Cilium CNI + FluxCD bootstrap
infrastructure/
├── controllers/          # Homelab HelmReleases/controllers
├── hetzner/              # Hetzner-specific controllers and configs
└── configs/              # Homelab post-CRD resources (MetalLB pools, ClusterIssuers)
apps/                     # Application workloads (deployed by Flux)
clusters/
├── homelab/              # Homelab Flux Kustomizations
└── hetzner/              # Hetzner Flux Kustomizations
```

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

## Reprovisioning

```bash
ansible-playbook site.yml   # Rebuilds everything; Flux reconciles workloads from Git
```

## Secrets

```bash
sops ansible/group_vars/all.sops.yml        # GitHub PAT, Cloudflare tokens
sops infrastructure/controllers/cloudflared/secret.yaml  # Tunnel token
sops infrastructure/controllers/nas/secret.yaml          # NAS credentials
sops infrastructure/controllers/tailscale-operator/secret.yaml          # Homelab Tailscale operator OAuth
sops infrastructure/hetzner/controllers/tailscale-operator/secret.yaml  # Hetzner Tailscale operator OAuth
```

Tailscale node auth keys and operator OAuth credentials have appeared in chat
history during setup. Rotate them when convenient and update only the SOPS
encrypted values.

## Termix

Termix is deployed as a LAN-only browser-based SSH access pod.

- Namespace: `termix`
- URL: `http://192.168.1.100:4090`
- Runs as a fixed pod on `k3s-node`
- Persists data at `/var/lib/termix-data` inside the LXC
- App manifests: `apps/termix/`
- Bootstrap notes: `apps/termix/README.md`

## About

This project exists to make my homelab fully reproducible. Every piece of infrastructure — from the LXC container to ingress routing — is defined in code, version-controlled, and automatically reconciled by FluxCD. There's no manual `kubectl apply` or SSH-and-edit. If the node dies, `ansible-playbook site.yml` rebuilds the entire stack and Flux restores all workloads from Git. The stack choices (Cilium over flannel, MetalLB over klipper, Traefik via Helm over k3s built-in) prioritize declarative configuration and GitOps manageability over convenience defaults.

## License

[MIT](LICENSE)
