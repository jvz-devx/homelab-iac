resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.homelab_tunnel_id

  config = {
    ingress = [
      {
        # Emergency override while k3s service DNS/routing is unhealthy.
        hostname = "live-rpc.jensvanzutphen.com"
        service  = "http://10.42.0.109:8000"
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

resource "cloudflare_zero_trust_tunnel_cloudflared" "hetzner_aiostreams" {
  account_id = var.cloudflare_account_id
  name       = "hetzner-aiostreams"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "hetzner_aiostreams" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id

  config = {
    ingress = [
      {
        hostname = "docs.jensvanzutphen.com"
        service  = "http://docs-site-auth.docs-site.svc.cluster.local:80"
      },
      {
        hostname = "pap.jensvanzutphen.com"
        service  = "http://cod-zombies-pap-checklist.cod-zombies-pap-checklist.svc.cluster.local:3000"
      },
      {
        hostname = "cv.jensvanzutphen.com"
        service  = "http://cv-web.cv-web.svc.cluster.local:3000"
      },
      {
        hostname = "cv.tunetap.xyz"
        service  = "http://cv-web.cv-web.svc.cluster.local:3000"
      },
      {
        hostname = "dart.tunetap.xyz"
        service  = "http://dartbingo.dartbingo.svc.cluster.local:3000"
      },
      {
        hostname = "prowlarr.tunetap.xyz"
        service  = "http://prowlarr.prowlarr.svc.cluster.local:9696"
      },
      {
        hostname = "nzbdav.jensvanzutphen.com"
        service  = "http://nzbdav.nzbdav.svc.cluster.local:3000"
      },
      {
        hostname = "aiostreams.tunetap.xyz"
        service  = "http://aiostreams.aiostreams.svc.cluster.local:3000"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

resource "cloudflare_dns_record" "aiostreams_tunetap" {
  provider = cloudflare.dns

  zone_id = var.tunetap_zone_id
  name    = "aiostreams"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "AIOStreams on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "docs_jensvanzutphen" {
  provider = cloudflare.dns

  zone_id = var.jensvanzutphen_zone_id
  name    = "docs"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "Docs site on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "pap_jensvanzutphen" {
  provider = cloudflare.dns

  zone_id = var.jensvanzutphen_zone_id
  name    = "pap"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "COD Zombies checklist on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "cv_jensvanzutphen" {
  provider = cloudflare.dns

  zone_id = var.jensvanzutphen_zone_id
  name    = "cv"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "CV site on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "cv_tunetap" {
  provider = cloudflare.dns

  zone_id = var.tunetap_zone_id
  name    = "cv"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "CV site on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "dart_tunetap" {
  provider = cloudflare.dns

  zone_id = var.tunetap_zone_id
  name    = "dart"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "Dartbingo on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "prowlarr_tunetap" {
  provider = cloudflare.dns

  zone_id = var.tunetap_zone_id
  name    = "prowlarr"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "Prowlarr on Hetzner via dedicated Cloudflare Tunnel."
}

resource "cloudflare_dns_record" "nzbdav_jensvanzutphen" {
  provider = cloudflare.dns

  zone_id = var.jensvanzutphen_zone_id
  name    = "nzbdav"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.hetzner_aiostreams.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "NZBDav on Hetzner via dedicated Cloudflare Tunnel."
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared_config.homelab
  id = "2014abcab19669d48bfb71bea759c299/f4f59044-cc55-41f0-a76a-96fdfeb42dc9"
}

import {
  to = cloudflare_dns_record.chat_api_tailnet
  id = "9c95c564e5855e0e653867092d5723a4/dc290f374efb2069a3ef1c26f4db39a8"
}

import {
  to = cloudflare_dns_record.docs_jensvanzutphen
  id = "9c95c564e5855e0e653867092d5723a4/4b13444ed18ef3c5fdd79e44932af232"
}

import {
  to = cloudflare_dns_record.pap_jensvanzutphen
  id = "9c95c564e5855e0e653867092d5723a4/146782839017f4ba6dd047c33e7f8bcb"
}

import {
  to = cloudflare_dns_record.cv_jensvanzutphen
  id = "9c95c564e5855e0e653867092d5723a4/592370c9869fb174e70cdfa97398d9a4"
}

import {
  to = cloudflare_dns_record.nzbdav_jensvanzutphen
  id = "9c95c564e5855e0e653867092d5723a4/a51febb5da062875ac31a071744e22b5"
}

import {
  to = cloudflare_dns_record.cv_tunetap
  id = "7eb0d762118d7a18c36ccf6cbda62c57/2b86d4cfffce3179eb3162c7fe2f371c"
}

import {
  to = cloudflare_dns_record.dart_tunetap
  id = "7eb0d762118d7a18c36ccf6cbda62c57/34ae94b9018039c5d46444cee9f85fb0"
}

import {
  to = cloudflare_dns_record.prowlarr_tunetap
  id = "7eb0d762118d7a18c36ccf6cbda62c57/af2d9debc4af1ce80ec95e31b0620d13"
}
