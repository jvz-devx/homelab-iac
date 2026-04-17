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

echo "fetching kubeconfig from $NODE …"
ssh -o ConnectTimeout=5 "$NODE" 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s|server: https://127.0.0.1:6443|server: https://${SERVER_HOST}:6443|" \
  > "$OUT"

chmod 600 "$OUT"
echo "wrote $OUT"
echo "re-enter 'nix develop' (or 'exec \$SHELL') so KUBECONFIG picks it up."
