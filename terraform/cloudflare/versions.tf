terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
}

provider "cloudflare" {
  alias     = "dns"
  api_token = var.cloudflare_dns_api_token
}
