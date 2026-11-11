# Universe backups

`rocket-sim-backup` runs hourly at minute 17 UTC. It copies the atomic
`/data/universe.json` save only when it differs from the newest backup and
keeps the newest 48 changed saves, not necessarily 48 hours of history.
No save yet means a quiet successful run.

The 1Gi `rocket-sim-backups` PVC uses `local-path-retain`, managed by the
Hetzner infrastructure-configs layer. The existing k3s local-path provisioner
stores both volumes on `hetzner-k3s-2`. The backup pod selects that node to
match the data PV's affinity. RWO allows the running server and backup pod
to mount the data volume together on the same node.

This is a second volume on the same disk, not an off-site backup. It does
not protect against losing the node or disk. Local-path does not enforce
the requested 1Gi quota; watch disk space as saves grow.

## Deletion and rollback

`backup-pvc.yaml` is separate from `pvc.yaml`, added in commit `3f280ab`.
When reverting that commit, preserve the backup entries if Git reports a
kustomization conflict. The backup PVC opts out of Flux pruning. If deleting
the namespace removes the PVC anyway, the PV's `Retain` policy leaves its
directory on disk. The original data PVC still uses `Delete` and is not
protected by this change.

After PVC deletion, a retained PV is `Released`; recreating a PVC with the
same name does not automatically reconnect it. Record the PV name and path
with `kubectl get pv <pv> -o yaml` and recover/rebind that volume deliberately
before resuming backups. Do not delete its directory or assume a newly
provisioned empty PVC contains the old backups.

## Restore

Use the Hetzner kubeconfig. Restore during a maintenance window:

1. Suspend the backup CronJob and Flux `apps` reconciliation temporarily so
   they cannot race the restore or reset the replica count. Wait for any
   active backup job to finish.
2. Scale `deployment/rocket-sim` to 0 in namespace `rocket-sim` and wait for
   the server pod to terminate. Its SIGTERM handler writes one final save.
3. Use a temporary maintenance pod on `hetzner-k3s-2`, running as uid/gid
   1000 with fsGroup 1000. Mount `rocket-sim-backups` read-only at `/backup`
   and `rocket-sim-data` read-write at `/data`. Inspect the backup list and
   choose a valid `universe-<UTC timestamp>.json`.
4. Copy the chosen file to `/data/universe.json.restore`, then rename it to
   `/data/universe.json`. Remove the old `/data/universe.json.1` so a newer
   fallback cannot override the chosen restore. Check the restored hash.
5. Delete the maintenance pod, scale the server to 1 and check startup logs
   and readiness. The server restores the newest valid save on startup.
6. Resume the backup CronJob and Flux `apps` reconciliation.

Do not restore into the live server's volume while it is running.
