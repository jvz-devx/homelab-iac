# Hetzner Cluster

This is the Flux entrypoint for the second k3s cluster on Hetzner Cloud.

The Hetzner cluster is intentionally a separate Kubernetes control plane, not
an extra node in the homelab cluster. The two clusters work together by sharing:

- the same GitOps repository
- the same SOPS age key model
- the same Ansible roles
- separate Flux cluster paths: `clusters/homelab` and `clusters/hetzner`
- separate kubeconfigs: `kubeconfig` and `kubeconfig-hetzner`
- Tailscale routing for explicitly shared services

Keep cloud-safe resources under `infrastructure/hetzner/**` and
Hetzner-specific apps under a dedicated path before wiring them into this
entrypoint. Do not point this cluster at the LAN-only homelab `apps/` or
`infrastructure/controllers/` trees unless those manifests have been split into
portable bases and cluster overlays.

## Cross-Cluster Services

Hetzner consumes homelab CLIProxyAPI through the Tailscale Kubernetes Operator:

```text
cliproxyapi.remote-homelab.svc.cluster.local:8317
  -> ts-cliproxyapi-*.tailscale.svc.cluster.local
  -> cliproxyapi-homelab.zebu-dorian.ts.net
```

Do not restore the old `EndpointSlice` that pointed at the homelab pod IP
`10.42.0.31`; pod IPs change on restart. Use operator-managed egress Services
for stable shared app traffic.
