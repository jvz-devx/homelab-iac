resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.homelab_tunnel_id

  config = {
    ingress = [
      {
        hostname = "docs.jensvanzutphen.com"
        service  = var.docs_site_tailnet_service
      },
      {
        hostname = "*.jensvanzutphen.com"
        service  = var.homelab_traefik_service
      },
      {
        hostname = "*.tunetap.xyz"
        service  = var.homelab_traefik_service
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "chat_api_tailnet" {
  provider = cloudflare.dns

  zone_id = var.jensvanzutphen_zone_id
  name    = "chat-api"
  content = var.cliproxyapi_tailnet_ipv4
  type    = "A"
  ttl     = 1
  proxied = false
  comment = "Private Tailscale-only CLIProxyAPI endpoint managed by Terraform."
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared_config.homelab
  id = "2014abcab19669d48bfb71bea759c299/f4f59044-cc55-41f0-a76a-96fdfeb42dc9"
}
