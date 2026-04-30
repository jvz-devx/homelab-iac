#!/usr/bin/env bash
# Run repository validation checks.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TOFU_MODULES=(
  "$ROOT/terraform/cloudflare"
  "$ROOT/terraform/hetzner"
)
ANSIBLE_PLAYBOOKS=(
  "$ROOT/ansible/site.yml"
  "$ROOT/ansible/hetzner.yml"
  "$ROOT/ansible/flux-bootstrap.yml"
)

run_tofu_fmt() {
  if ! command -v tofu >/dev/null; then
    echo "tofu not in PATH. Run inside 'nix develop'." >&2
    return 1
  fi

  tofu fmt -recursive -check "$ROOT/terraform"
}

run_tofu_validate() {
  if ! command -v tofu >/dev/null; then
    echo "tofu not in PATH. Run inside 'nix develop'." >&2
    return 1
  fi

  for module in "${TOFU_MODULES[@]}"; do
    echo "==> tofu validate ${module#$ROOT/}"
    tofu -chdir="$module" init -backend=false -input=false >/dev/null
    tofu -chdir="$module" validate
  done
}

run_ansible_syntax() {
  if ! command -v ansible-playbook >/dev/null; then
    echo "ansible-playbook not in PATH. Run inside 'nix develop'." >&2
    return 1
  fi

  export ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg"

  for playbook in "${ANSIBLE_PLAYBOOKS[@]}"; do
    echo "==> ansible syntax ${playbook#$ROOT/}"
    ansible-playbook --syntax-check "$playbook"
  done
}

case "${1:-all}" in
  all)
    run_tofu_fmt
    run_tofu_validate
    run_ansible_syntax
    ;;
  tofu-fmt)
    run_tofu_fmt
    ;;
  tofu-validate)
    run_tofu_validate
    ;;
  ansible-syntax)
    run_ansible_syntax
    ;;
  *)
    echo "Usage: $0 [all|tofu-fmt|tofu-validate|ansible-syntax]" >&2
    exit 2
    ;;
esac
