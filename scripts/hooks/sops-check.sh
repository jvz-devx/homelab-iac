#!/usr/bin/env bash
# Verify that SOPS-managed files are actually encrypted before committing.
# Catches accidental commits of plaintext secrets.

set -euo pipefail

exit_code=0

for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi

  # .sops.yml files (Ansible secrets) should be fully encrypted — check for sops metadata
  if [[ "$file" == *.sops.yml ]] || [[ "$file" == *.sops.yaml ]]; then
    if ! grep -q "sops:" "$file" || ! grep -q "ENC\[AES256_GCM," "$file"; then
      echo "ERROR: $file appears to contain unencrypted data"
      echo "  Run: sops -e -i $file"
      exit_code=1
    fi
  fi

  # secret.yaml files (k8s secrets) should have encrypted data/stringData values
  if [[ "$file" == *secret.yaml ]]; then
    # Check if it's a k8s Secret with data/stringData that isn't encrypted
    if grep -qE "^(data|stringData):" "$file"; then
      if ! grep -q "ENC\[AES256_GCM," "$file"; then
        echo "ERROR: $file has unencrypted data/stringData values"
        echo "  Run: sops -e -i $file"
        exit_code=1
      fi
    fi
  fi
done

exit $exit_code
