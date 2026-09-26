#!/usr/bin/env bash
# Move a local-path volume to another k3s node, keeping its data.
#
#   scripts/move-local-pv.sh NAMESPACE PVC TARGET_NODE WORKLOAD...
#
# WORKLOADs are what mounts the volume, e.g. deploy/postgres cronjob/backup.
# Run with the `apps` Flux Kustomization suspended (so Flux does not scale the
# workloads back up or recreate the claim early), then commit the workloads'
# nodeSelector for TARGET_NODE and resume Flux: it recreates the PVC from git,
# which binds to the volume this script pre-creates on TARGET_NODE.
#
# Steps: scale the workloads to 0 (suspend cronjobs) → mark the old PV Retain
# → copy the directory node to node with ownership preserved → compare file
# counts and bytes → delete the PVC and the old PV object (its data stays on
# the old node) → create a PV on TARGET_NODE bound to the same claim name.
# Node SSH logins come from NODE_SSH_<node_with_underscores> (default
# root@<the node's InternalIP>).
set -euo pipefail

ns=${1:?namespace}; pvc=${2:?pvc}; target=${3:?target node}; shift 3
[ $# -gt 0 ] || { echo "name the workloads that mount $pvc" >&2; exit 2; }
workloads=("$@")

ssh_for() {
  local v="NODE_SSH_${1//-/_}"
  [ -n "${!v:-}" ] && { echo "${!v}"; return; }
  echo "root@$(kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
}
node_ssh() { local n=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=10 "$(ssh_for "$n")" "$@"; }

pv=$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
[ -n "$pv" ] || { echo "$ns/$pvc is not bound" >&2; exit 1; }
spec=$(kubectl get pv "$pv" -o json)
path=$(jq -r '.spec.local.path // .spec.hostPath.path' <<<"$spec")
source_node=$(jq -r '.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]' <<<"$spec")
capacity=$(jq -r '.spec.capacity.storage' <<<"$spec")
modes=$(jq -c '.spec.accessModes' <<<"$spec")
class=$(jq -r '.spec.storageClassName' <<<"$spec")
[ "$source_node" != "$target" ] || { echo "$pv is already on $target" >&2; exit 1; }
echo "$ns/$pvc: $pv ($capacity) on $source_node:$path -> $target"

echo "== stopping workloads"
for w in "${workloads[@]}"; do
  case $w in
    cronjob/*) kubectl -n "$ns" patch "$w" -p '{"spec":{"suspend":true}}' ;;
    *) kubectl -n "$ns" scale "$w" --replicas=0 ;;
  esac
done
for _ in $(seq 60); do
  users=$(kubectl -n "$ns" get pods -o json | jq --arg c "$pvc" '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c))] | length')
  [ "$users" = 0 ] && break
  sleep 5
done
[ "$users" = 0 ] || { echo "pods still mount $pvc; not copying" >&2; exit 1; }

echo "== keeping the old data: $pv reclaimPolicy Retain"
kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

echo "== copying"
node_ssh "$target" "mkdir -p '$path' && [ -z \"\$(ls -A '$path')\" ]" || { echo "$target:$path exists and is not empty" >&2; exit 1; }
node_ssh "$source_node" "tar -C '$path' --numeric-owner -cpf - ." | node_ssh "$target" "tar -C '$path' --numeric-owner -xpf -"
mode_owner=$(node_ssh "$source_node" "stat -c '%a %u:%g' '$path'")
node_ssh "$target" "chmod ${mode_owner% *} '$path' && chown ${mode_owner#* } '$path'"
count() { node_ssh "$1" "find '$path' | wc -l; du -sb '$path' | cut -f1" | tr '\n' ' '; }
src=$(count "$source_node"); dst=$(count "$target")
echo "files bytes: $source_node $src / $target $dst"
[ "$src" = "$dst" ] || { echo "copy differs; old volume untouched apart from Retain" >&2; exit 1; }

echo "== switching the claim to $target"
kubectl -n "$ns" delete pvc "$pvc" --wait=true
kubectl delete pv "$pv" --wait=true
new="$pv-$target"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $new
  labels:
    homelab/moved-from: $source_node
spec:
  capacity:
    storage: $capacity
  accessModes: $modes
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $class
  volumeMode: Filesystem
  claimRef:
    namespace: $ns
    name: $pvc
  local:
    path: $path
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [$target]
EOF
cat <<EOF
Done. $new on $target waits for $ns/$pvc.
Next: commit the nodeSelector for $target on ${workloads[*]}, push, and
resume Flux (flux resume kustomization apps); it recreates the claim, which
binds to $new, and scales the workloads back up.
The old copy stays at $source_node:$path until you delete it.
Roll back: delete PVC $ns/$pvc and PV $new, recreate a PV named $pv on
$source_node:$path bound to the claim, and revert the nodeSelector.
EOF
