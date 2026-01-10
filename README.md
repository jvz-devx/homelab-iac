# Homelab IaC

Infrastructure-as-Code for a homelab k3s cluster managed with FluxCD, provisioned with Ansible, secrets encrypted with SOPS/Age.

## Architecture

- **Proxmox** host at 192.168.1.202
- **k3s** single-node cluster in LXC 101 (192.168.1.100)
- **FluxCD** for GitOps continuous delivery
- **Cloudflare Tunnel** exposing services on `jensvanzutphen.com`
- **SOPS/Age** for secret encryption
- **Ansible** for initial provisioning and disaster recovery

## Prerequisites

- Nix with flakes enabled
- direnv (optional, for auto-loading devShell)
- Age key at `~/.config/sops/age/keys.txt`
- SSH access to Proxmox host and k3s node
- GitHub token with repo access

## Quick Start

```bash
# Enter dev shell
nix develop

# Or with direnv
direnv allow

# Provision k3s node
cd ansible
ansible-playbook site.yml

# Bootstrap FluxCD
ansible-playbook flux-bootstrap.yml
```

## Disaster Recovery

### Full Rebuild (from scratch)

1. Recreate LXC on Proxmox (see docs/proxmox-setup.md or Phase 1 notes)
2. Run provisioning:
   ```bash
   cd ansible
   ansible-playbook site.yml
   ansible-playbook flux-bootstrap.yml
   ```
3. FluxCD will automatically reconcile all workloads from Git

### Partial Recovery

- **k3s reset**: `ansible-playbook site.yml` (idempotent)
- **Flux re-bootstrap**: `ansible-playbook flux-bootstrap.yml`
- **Single app**: `flux reconcile kustomization apps`

## Repository Structure

```
ansible/          # Ansible playbooks and roles
clusters/         # FluxCD cluster entrypoints
infrastructure/   # Core infrastructure (cert-manager, ingress, cloudflared)
apps/             # Application deployments
```

## Secrets Management

Secrets are encrypted with SOPS using Age encryption. To edit:

```bash
sops ansible/group_vars/all.sops.yml
sops infrastructure/cloudflared/secret.yaml
```

Never commit plaintext secrets. The `.sops.yaml` config ensures automatic encryption.
