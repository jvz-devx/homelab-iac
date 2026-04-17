#!/usr/bin/env bash
# Trigger Flux reconcile, optionally scoped to one Kustomization.
#
# Requires the devShell (flux + kubectl in PATH, KUBECONFIG pointing at a
# working kubeconfig). Run scripts/fetch-kubeconfig.sh once if needed.
#
# Usage:
#   scripts/reconcile.sh             # git source + full chain in order
#   scripts/reconcile.sh <name>      # one specific kustomization
#   scripts/reconcile.sh -s          # just pull the git source, nothing else
set -euo pipefail

if ! command -v flux >/dev/null; then
  echo "flux not in PATH. Run inside 'nix develop'." >&2
  exit 1
fi

if ! kubectl -n flux-system get ns >/dev/null 2>&1; then
  echo "kubectl can't reach the cluster." >&2
  echo "If KUBECONFIG ($KUBECONFIG) is missing, run: ./scripts/fetch-kubeconfig.sh" >&2
  exit 1
fi

# Always refresh the git source first — otherwise a Kustomization reconcile
# would apply the last-fetched revision, which may predate your push.
flux reconcile source git flux-system

if [[ "${1:-}" == "-s" ]]; then
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  flux reconcile kustomization "$1"
else
  # Respect the dependsOn order: controllers → configs → apps. `flux
  # reconcile` blocks until the Kustomization is Ready, so a failure in
  # layer N stops before layer N+1 touches the cluster — exactly the
  # phased-deploy behaviour we want.
  for k in infrastructure-controllers infrastructure-configs apps; do
    flux reconcile kustomization "$k"
  done
fi

echo
flux get kustomizations
