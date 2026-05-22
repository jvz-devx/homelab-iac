variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
  default     = "2014abcab19669d48bfb71bea759c299"
}

variable "cloudflare_dns_api_token" {
  description = "Cloudflare zone DNS API token. Set by scripts/cloudflare-env.sh from SOPS."
  type        = string
  sensitive   = true
}

variable "homelab_tunnel_id" {
  description = "Existing Cloudflare Tunnel ID for homelab."
  type        = string
  default     = "f4f59044-cc55-41f0-a76a-96fdfeb42dc9"
}

variable "homelab_traefik_service" {
  description = "In-cluster service URL reached by cloudflared."
  type        = string
  default     = "http://traefik.traefik.svc.cluster.local:80"
}

variable "docs_site_tailnet_service" {
  description = "Hetzner docs-site service reached by the docs-site cloudflared connector."
  type        = string
  default     = "http://docs-site.docs-site.svc.cluster.local:80"
}

variable "jensvanzutphen_zone_id" {
  description = "Cloudflare zone ID for jensvanzutphen.com."
  type        = string
  default     = "9c95c564e5855e0e653867092d5723a4"
}

variable "cliproxyapi_tailnet_ipv4" {
  description = "Tailscale IPv4 for the homelab CLIProxyAPI service proxy."
  type        = string
  default     = "100.71.48.37"
}
