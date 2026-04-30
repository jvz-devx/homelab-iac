#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
export CLOUDFLARE_API_TOKEN="$(
  sops -d "$ROOT/ansible/group_vars/all.sops.yml" |
    yq -r '.cloudflare_account_api_token'
)"

export TF_VAR_cloudflare_dns_api_token="$(
  sops -d "$ROOT/ansible/group_vars/all.sops.yml" |
    yq -r '.cloudflare_api_token'
)"

if [[ -z "${CLOUDFLARE_API_TOKEN}" || "${CLOUDFLARE_API_TOKEN}" == "null" ]]; then
  echo "cloudflare_account_api_token is missing from ansible/group_vars/all.sops.yml" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -z "${TF_VAR_cloudflare_dns_api_token}" || "${TF_VAR_cloudflare_dns_api_token}" == "null" ]]; then
  echo "cloudflare_api_token is missing from ansible/group_vars/all.sops.yml" >&2
  return 1 2>/dev/null || exit 1
fi

echo "Exported Cloudflare tokens for Terraform/OpenTofu"
