#!/usr/bin/env bash
# Fetch the k3s kubeconfig from the cluster node into $PWD/kubeconfig.
#
# This is a one-time setup step per workstation. The devShell's KUBECONFIG
# already points at $PWD/kubeconfig (see flake.nix); this script just
# populates it. Re-run if the cluster is reprovisioned.
#
# K3S_NODE can override the default ssh target.
set -euo pipefail

NODE="${K3S_NODE:-root@192.168.1.100}"
SERVER_HOST="${K3S_SERVER_HOST:-192.168.1.100}"
OUT="$(git rev-parse --show-toplevel)/kubeconfig"
TMP="$(mktemp "${OUT}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

echo "fetching kubeconfig from $NODE …"
ssh -o ConnectTimeout=5 "$NODE" 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s|server: https://127.0.0.1:6443|server: https://${SERVER_HOST}:6443|" \
  > "$TMP"

if [[ ! -s "$TMP" ]]; then
  echo "fetched kubeconfig is empty; leaving $OUT unchanged" >&2
  exit 1
fi

if ! grep -q '^apiVersion: v1$' "$TMP"; then
  echo "fetched kubeconfig is missing apiVersion: v1; leaving $OUT unchanged" >&2
  exit 1
fi

if ! grep -q '^clusters:$' "$TMP"; then
  echo "fetched kubeconfig is missing clusters; leaving $OUT unchanged" >&2
  exit 1
fi

if ! grep -q "server: https://${SERVER_HOST}:6443" "$TMP"; then
  echo "fetched kubeconfig does not point at https://${SERVER_HOST}:6443; leaving $OUT unchanged" >&2
  exit 1
fi

chmod 600 "$TMP"
mv "$TMP" "$OUT"
trap - EXIT

echo "wrote $OUT"
echo "re-enter 'nix develop' (or 'exec \$SHELL') so KUBECONFIG picks it up."
