# Nodes and workload placement

The homelab cluster has two k3s nodes on two Proxmox hosts. They are separate
Proxmox machines, not a Proxmox cluster.

| Node | Role | Where | Resources |
|---|---|---|---|
| `k3s-node` (192.168.1.100) | server (control plane, SQLite datastore) + workloads | LXC 101 on node2 (192.168.1.202, Intel N100) | 3 cores, 8 GB |
| `k3s-worker-1` (192.168.1.101) | agent (workloads only) | LXC 102 on node1 (192.168.1.201, i5-10400T, also runs Home Assistant and hermes) | 6 cores, 12 GB, 64 GB disk |

Both run k3s v1.31.4+k3s1, Cilium (VXLAN tunnel, kube-proxy replacement) and
the MetalLB speaker. The Tailscale subnet router and the API endpoint stay on
`k3s-node`.

## Placement

Apps are pinned with a `nodeSelector` on `kubernetes.io/hostname`, set by a
patch in each app's `kustomization.yaml` (search for "Priority").

| Priority | Node | Apps |
|---|---|---|
| 1 | `k3s-node` (N100) | toepen (+ valkey), resonance (bot, pot-server, redis), steve-website |
| 2 | `k3s-worker-1` | strikers, klavier (app, ws-server, redis, postgres), boodschappen (+ weekly reminder CronJob), hermes-friend, liverpc-docs, minecraft-resource-pack |

Infrastructure (Flux, cert-manager, coredns, traefik, cloudflared,
external-dns, metallb, tailscale operator, rclone-nas, ...) is not pinned and
goes wherever the scheduler puts it.

To change an app's node: edit the patch in its `kustomization.yaml`. If the
app has a `local-path` volume, move the volume first (below); a pod pinned to a
node without its volume stays Pending.

## Adding or rebuilding the worker

```bash
nix develop
cd ansible && ansible-playbook k3s-worker.yml
```

`k3s-worker.yml` is separate from `site.yml` on purpose: `site.yml` stops and
reconfigures LXC 101 on every `proxmox` host and makes every `k3s_cluster`
host the Tailscale subnet router. The worker's Proxmox host is in
`proxmox_workers` and the node in `k3s_agents`, so `site.yml` never touches
them. Per-host settings live in `ansible/host_vars/` (`pve-node1.yml` for the
LXC, `k3s-worker-1.yml` for k3s flags).

The playbook:
1. loads the kernel modules Cilium and k3s need on node1 (a container shares
   the host kernel and cannot load them) and persists them in
   `/etc/modules-load.d/k3s-worker.conf`;
2. creates the LXC with `roles/proxmox_lxc` (re-running it stops and restarts
   the worker LXC to apply config);
3. runs `roles/k3s_prereqs` (the `br_netfilter` modprobe inside the container
   fails and is ignored; the host has it loaded);
4. joins with `roles/k3s_agent`, which reads the server's node token on
   `k3s-node` without logging it.

A second worker: add a host to `proxmox_workers` and `k3s_agents` with its own
`host_vars` (unique `lxc_id`, `lxc_hostname`, `lxc_ip`).

## Moving a local-path volume between nodes

`local-path` volumes live in `/var/lib/rancher/k3s/storage/` on one node and
bind their pods to it. `scripts/move-local-pv.sh` moves one with its data:

```bash
flux suspend kustomization apps
scripts/move-local-pv.sh NAMESPACE PVC TARGET_NODE deploy/NAME [cronjob/NAME ...]
# commit the nodeSelector for TARGET_NODE on those workloads, push
flux resume kustomization apps
```

It scales the workloads to 0 (suspends CronJobs), sets the old PV to
`Retain`, copies the directory node to node with ownership preserved, checks
file counts and bytes, deletes the PVC and the old PV object, and creates a PV
on the target node pre-bound to the same claim. Flux recreates the PVC from
git and it binds to that PV. The old data stays on the source node until you
delete it; the script prints the rollback.

After resuming, check that Flux really recreated the claims and scaled the
workloads up (`kubectl get pvc,deploy -n NAMESPACE`). On 2026-09-26 the `apps`
reconcile timed out against the overloaded API server (see below); applying
the app server-side under Flux's field manager did the same job:
`kubectl kustomize apps/NAME | kubectl apply --server-side --field-manager=kustomize-controller --force-conflicts -f -`
(the SOPS-encrypted Secrets are refused by the API server and left as they are).
Also unsuspend any CronJob the script suspended; Flux does not reset that field.

Moved on 2026-09-26 (old copies still on `k3s-node`, PVs named
`<old pv>-k3s-worker-1`): strikers-data (2.5 GB), hermes-friend-data (280 MB),
klavier postgres-data (50 MB), boodschappen-data.

## The k3s datastore (why the worker was added)

`k3s-node` runs k3s on the default SQLite datastore (kine). On 2026-09-26
`state.db` was 5.4 GB for a few hundred objects: kine's compaction was 2.2M
revisions behind (current 27.7M, compacted 25.55M) and not moving. Every list
and watch scans that history, so `k3s-server` used 2.3-2.75 of the N100's 3
cores, the node's CPU pressure was 38-47% and workloads were starved (the
Strikers game server's 50 Hz ticks started up to ~200 ms late).

What fed it (about 2.1 writes/s over 40 h):
- six Flux leader-election leases renewed every ~5 s: about half of all rows.
  Leader election is now off (`clusters/homelab/kustomization.yaml`), since
  each controller runs a single replica.
- Flux image scanning (`clusters/homelab/image-automation.yaml`, 1 minute on
  purpose for fast deploys): the most bytes, 2-3 KB status patches.
- node, apiserver and cert-manager leases.

Still to do: clear the backlog. Either restart k3s with `--cluster-init`
(k3s migrates SQLite to embedded etcd, which compacts and defragments
properly) or compact and vacuum `state.db` offline, as was done in June 2026
(12.8 GB before). Both need a k3s restart, so every app on the cluster goes
down for a few minutes. `server/db/etcd/` holds only a 17-byte `name` file from
February 2026; it is not an etcd data directory.

Checking the datastore (read-only):

```bash
ssh root@192.168.1.100 "sqlite3 -readonly 'file:/var/lib/rancher/k3s/server/db/state.db?mode=ro' \
  \"select max(id) from kine; select prev_revision from kine where name='compact_rev_key' order by id desc limit 1;\""
```

The difference between the two numbers is the compaction lag.
