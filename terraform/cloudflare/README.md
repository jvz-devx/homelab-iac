# Cloudflare Terraform

Declarative Cloudflare account and edge configuration.

This layer manages Cloudflare resources that Kubernetes cannot own directly.
Kubernetes `external-dns` owns per-Ingress DNS records; Terraform owns the
Cloudflare Tunnel ingress rules that decide which hostnames the tunnel accepts.

## Usage

```bash
nix develop
source scripts/cloudflare-env.sh
tofu -chdir=terraform/cloudflare init
tofu -chdir=terraform/cloudflare plan
tofu -chdir=terraform/cloudflare apply
```

## Managed Resources

- Existing `homelab` Cloudflare Tunnel config:
  - `*.jensvanzutphen.com -> http://traefik.traefik.svc.cluster.local:80`
  - `*.tunetap.xyz -> http://traefik.traefik.svc.cluster.local:80`
  - fallback `http_status:404`

## Bootstrap Token

The provider uses `CLOUDFLARE_API_TOKEN`. Load it from SOPS with
`scripts/cloudflare-env.sh`.

The token must be account-scoped and able to manage Cloudflare Tunnel config.
The zone-level DNS token used by cert-manager/external-dns is intentionally not
enough for this Terraform layer.
