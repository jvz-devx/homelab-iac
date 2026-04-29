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

For real cross-cluster service traffic, add an explicit private network layer
between `192.168.1.100` and the Hetzner node later (WireGuard or Tailscale),
then enable a higher-level discovery/routing layer such as Cilium Cluster Mesh
or a service mesh. The CIDRs above are already prepared for that; do not rely on
Kubernetes node joining across the public internet.
