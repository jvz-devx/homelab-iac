# Cloudflare Terraform

Declarative Cloudflare account and edge configuration.

This layer manages Cloudflare resources that Kubernetes cannot own directly.
Kubernetes `external-dns` owns per-Ingress DNS records; Terraform owns the
Cloudflare Tunnel ingress rules that decide which hostnames the tunnel accepts.
It also owns DNS records that are intentionally not Kubernetes ingress records,
such as private Tailscale-only hostnames.

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
- Private Tailscale-only DNS:
  - `chat-api.jensvanzutphen.com -> 100.71.48.37`

`chat-api.jensvanzutphen.com` is deliberately unproxied. It resolves to a
Tailscale CGNAT address, so it only works from devices connected to the tailnet.

## Bootstrap Token

The default provider uses `CLOUDFLARE_API_TOKEN`. A second aliased provider uses
`TF_VAR_cloudflare_dns_api_token` for zone DNS records. Load both from SOPS with
`scripts/cloudflare-env.sh`.

The token must be account-scoped and able to manage Cloudflare Tunnel config.
The zone-level DNS token used by cert-manager/external-dns is intentionally not
enough for the tunnel resource, but is used by the DNS-record resource.
