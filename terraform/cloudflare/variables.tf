variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
  default     = "2014abcab19669d48bfb71bea759c299"
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
