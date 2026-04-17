# Termix — deferred work

Two independent cleanups queued for later. They don't depend on each other — pick whichever fits the moment.

---

## 1. Retire the 192.168.1.111 LoadBalancer IP

### Why

When HTTPS was introduced, `service.yaml` was intentionally left as `type: LoadBalancer` with `loadBalancerIP: 192.168.1.111` so the existing `http://192.168.1.111` sessions didn't break during the rollout. Now that traffic goes through Traefik at `https://termix.jensvanzutphen.com`, the direct LB is dead weight and occupies an IP in the MetalLB pool.

### Precondition

Confirm nothing still reaches Termix via `192.168.1.111`:

- Your own browser: close any remaining `http://192.168.1.111` tabs, open `https://termix.jensvanzutphen.com` and keep using it for a day or two.
- Other clients: `kubectl -n termix logs deploy/termix | grep -v 192.168.1.110` should be quiet. The `.110` entries come from Traefik forwarding; anything else is a direct LB hit worth investigating before proceeding.

### Change

Edit `apps/termix/service.yaml`:

```yaml
spec:
  type: ClusterIP         # was: LoadBalancer
  # loadBalancerIP removed  (was: 192.168.1.111)
```

Commit, push, reconcile:
```
./scripts/reconcile.sh apps
kubectl -n termix get svc termix         # no EXTERNAL-IP column value
kubectl -n metallb-system get ipaddresspool -o yaml | grep -A1 pool   # .111 back in pool
curl -sSI https://termix.jensvanzutphen.com | head -1   # still HTTP/2 200
```

### Rollback

Revert `service.yaml` (keep `type: LoadBalancer` + the `loadBalancerIP`), push, reconcile. MetalLB re-assigns `.111` within seconds. No data or cert loss.

---

## 2. Migrate PVC from local-path to NAS-backed storage

### Why

Termix currently writes to a `local-path`-backed PVC (`termix-data`, 5Gi, RWO). Data lives on the k3s LXC's local disk:

```
StorageClass: local-path (rancher.io/local-path, reclaimPolicy: Delete)
```

If the LXC is reprovisioned, every user / SSH credential / host entry / session log Termix has stored is gone. Copyparty already does the right thing: a pre-provisioned NFS-backed PV served by `rclone-nas` (FTP→NFS bridge on 192.168.1.100:2049) — see `apps/copyparty/deployment.yaml` lines 1–33 for the template.

Goal: give Termix the same durability, **without losing current data**.

### Precondition — a non-Termix way to reach this machine

**This migration takes Termix offline for ~2 minutes** (SQLite can't safely be rsync'd while Termix is writing). Before starting, make sure you can reach `pc-02` (or wherever you run Claude Code) via a path that doesn't go through Termix:

- Direct SSH from laptop/phone over the LAN — easiest
- Tailscale, if enabled
- Physical keyboard on the host

If you're running Claude Code in a `tmux` session started by Termix's SSH backend, re-attach from the backup path (`tmux attach`). Otherwise, start a fresh `claude` session from there.

### Plan

#### 2.1 Add the new PV + PVC alongside the old one (declarative)

Add a new PV + PVC to the app, in addition to the existing `termix-data` PVC. Following the `copyparty-nas` pattern, but scoped to a `termix/` subdirectory on the NAS so copyparty and termix don't share a flat root:

```yaml
# apps/termix/pvc.yaml — replace contents
---
# Old local-path PVC — kept during migration, removed in 2.5.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: termix-data
  namespace: termix
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
---
# New NAS-backed PV (cluster-scoped, no namespace).
apiVersion: v1
kind: PersistentVolume
metadata:
  name: termix-nas
spec:
  capacity:
    storage: 5Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  mountOptions: [nfsvers=3, port=2049, mountport=2049, tcp, nolock]
  nfs:
    server: 192.168.1.100
    path: /
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: termix-data-nas
  namespace: termix
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  resources:
    requests:
      storage: 5Gi
  volumeName: termix-nas
```

Note: `nfs.path: /` serves the whole NAS root (same as copyparty); subdir isolation happens pod-side via `subPath` in 2.4. If you want on-PV isolation instead, set `nfs.path: /termix` and drop the `subPath` later — but that only works if rclone exports the subdir correctly.

Commit, push, reconcile:
```
./scripts/reconcile.sh apps
kubectl -n termix get pvc    # both PVCs should be Bound
```

#### 2.2 Scale Termix down

```
kubectl -n termix scale deploy termix --replicas=0
kubectl -n termix get pods -w   # wait until the pod is Terminated
```

Termix is offline from this point until 2.4 completes.

#### 2.3 Copy data with a helper pod

```
kubectl -n termix apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-migrate
  namespace: termix
spec:
  restartPolicy: Never
  containers:
    - name: rsync
      image: alpine:3.21
      command:
        - sh
        - -c
        - |
          apk add --no-cache rsync >/dev/null
          mkdir -p /dst/termix
          rsync -aHAXv --info=progress2 /src/ /dst/termix/
          echo "--- /dst/termix contents ---"
          ls -la /dst/termix
      volumeMounts:
        - { name: src, mountPath: /src }
        - { name: dst, mountPath: /dst }
  volumes:
    - name: src
      persistentVolumeClaim: { claimName: termix-data }
    - name: dst
      persistentVolumeClaim: { claimName: termix-data-nas }
EOF

kubectl -n termix logs -f pvc-migrate
# Expect: rsync summary + a directory listing containing Termix's SQLite
#         DB, config files, and anything else it had under /app/data.
kubectl -n termix delete pod pvc-migrate
```

Verify explicitly that the DB file landed and is a reasonable size:
```
kubectl -n termix run verify --rm -it --restart=Never --image=alpine:3.21 \
  --overrides='{"spec":{"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"termix-data-nas"}}],"containers":[{"name":"verify","image":"alpine:3.21","stdin":true,"tty":true,"command":["sh"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}]}}' \
  -- sh -c 'find /data/termix -maxdepth 2 -size +0 | head -20'
```

If ANY of this looks wrong (empty directory, missing DB file, size 0): **stop**. Do not delete the old PVC. Scale Termix back up with the old claim and investigate before retrying.

#### 2.4 Point Termix at the new PVC + scale up

Edit `apps/termix/deployment.yaml`:

```yaml
# Change only the claimName in the existing volumes block:
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: termix-data-nas    # was: termix-data

# And add subPath to the volume mount so Termix writes to /termix/ on the NAS:
          volumeMounts:
            - name: data
              mountPath: /app/data
              subPath: termix
```

Commit, push, reconcile:
```
./scripts/reconcile.sh apps
kubectl -n termix scale deploy termix --replicas=1
kubectl -n termix get pods -w
```

#### 2.5 Visually verify in Termix, then clean up

- Open `https://termix.jensvanzutphen.com`
- Log in with your existing user (the one that was there before the migration)
- Check: SSH credentials still present, host list still populated, recent connections still visible

Only when you're satisfied:

```yaml
# Remove the old PVC from apps/termix/pvc.yaml (delete its block).
```

Commit, push, reconcile. Flux removes the old `termix-data` PVC. Because local-path's reclaimPolicy is `Delete`, the underlying local data on the LXC is freed automatically.

### Rollback

At any point before 2.5 (clean-up), recovery is trivial: edit `apps/termix/deployment.yaml` to point `claimName` back at `termix-data`, reconcile, scale up. The old PVC was never touched, still bound to its local PV, still has the original data. The NAS PVC can stay around as an empty-but-Bound resource or be deleted.

After 2.5, the old PV is gone — rollback requires restoring from whatever backup you have. Which is why 2.5 only happens after visual verification in the UI.

### Nice-to-haves (not required for correctness)

- **Give the NAS PV its own subdir at the PV level** instead of pod-side `subPath`, if rclone can serve a sub-export cleanly. Makes the PV self-documenting ("this mounts the termix data, full stop").
- **Shrink the PV request**. 5Gi was a placeholder for local-path; on a shared NAS, 1Gi is probably plenty for a jump host.
- **Add a Job that periodically snapshots the SQLite DB** via `sqlite3 termix.db '.backup termix.db.bak'` to a second NAS path. Cheap belt-and-braces backup.
