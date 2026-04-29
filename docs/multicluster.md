# Multi-Cluster Model

This repository supports multiple independent k3s clusters.

| Cluster | Provider | Flux path | Kubeconfig |
|---|---|---|---|
| `homelab` | Proxmox LXC | `clusters/homelab` | `kubeconfig` |
| `hetzner` | Hetzner Cloud VM | `clusters/hetzner` | `kubeconfig-hetzner` |

The clusters "work together" through GitOps first: each cluster reconciles its
own Flux path from the same repo, uses the same SOPS Age trust root, and is
bootstrapped by the same Ansible roles. Shared code should be factored into
reusable bases only after a resource is known to be portable across both
environments.

Network ranges are intentionally non-overlapping:

| Cluster | Pods | Services | Node/private network |
|---|---|---|---|
| `homelab` | `10.42.0.0/16` | `10.43.0.0/16` | `192.168.1.0/24` |
| `hetzner` | `10.52.0.0/16` | `10.53.0.0/16` | `10.80.0.0/16` |

Do not reuse LAN-specific manifests directly on Hetzner. Current homelab
manifests include assumptions such as MetalLB LAN ranges, Cloudflare tunnel
routing, NAS mounts, and single-node resource limits.

Cross-cluster routing uses host-level Tailscale subnet routers on both k3s
nodes. See `docs/tailscale-routing.md` for the route advertisements, Tailscale
policy requirements, rollout steps, and verification commands. Do not rely on
Kubernetes node joining across the public internet.
