#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
export TF_VAR_hcloud_token="$(
  sops -d "$ROOT/ansible/group_vars/all.sops.yml" |
    yq -r '.hetzner_api_token'
)"

if [[ -z "${TF_VAR_hcloud_token}" || "${TF_VAR_hcloud_token}" == "null" ]]; then
  echo "hetzner_api_token is missing from ansible/group_vars/all.sops.yml" >&2
  return 1 2>/dev/null || exit 1
fi

echo "Exported TF_VAR_hcloud_token for Terraform/OpenTofu"
