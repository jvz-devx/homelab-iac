# Tailscale Cross-Cluster Routing

Host-level Tailscale subnet routers connect the homelab and Hetzner k3s
clusters without joining the Kubernetes control planes. The Tailscale
Kubernetes Operator runs on both clusters for stable service-level access where
raw pod IPs or ClusterIPs would be brittle.

| Node | Hostname | Advertised routes | Exit node |
|---|---|---|---|
| Homelab | `homelab-k3s` | `10.42.0.0/16`, `10.43.0.0/16` | No |
| Hetzner | `hetzner-k3s` | `10.52.0.0/16`, `10.53.0.0/16` | Yes |

The nodes use Tailscale's approved routes. This tailnet already has other
subnet routes, including a LAN route for `192.168.1.0/24`; accepting all routes
on the homelab node can break LAN return traffic unless the local LAN route is
protected. Ansible installs a route override in Tailscale table `52` so
`192.168.1.0/24` continues to use `eth0` on `homelab-k3s`.

## Tailnet Policy

Route and exit-node approval should be configured before running the Ansible
role because Tailscale route auto-approval is not retroactive. The Kubernetes
Operator also needs tag ownership that allows an operator device tagged
`tag:k8s-operator` to create proxy devices tagged `tag:k8s`.

Merge this shape into the existing tailnet policy without removing current
ACLs, grants, users, or groups:

```json
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin", "jvz-devx@github"],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "routes": {
      "10.42.0.0/16": ["autogroup:admin"],
      "10.43.0.0/16": ["autogroup:admin"],
      "10.52.0.0/16": ["autogroup:admin"],
      "10.53.0.0/16": ["autogroup:admin"]
    },
    "exitNode": ["autogroup:admin"]
  }
}
```

If the auth key is later changed to use tags, replace `autogroup:admin` with
the exact tag owner used by the key.

The operator uses OAuth credentials, not the node auth key. Store OAuth
credentials only in SOPS:

```bash
sops infrastructure/controllers/tailscale-operator/secret.yaml
sops infrastructure/hetzner/controllers/tailscale-operator/secret.yaml
```

Rotate the node auth key and operator OAuth client when convenient because both
were exposed in chat during initial setup.

## Operator-Managed Services

No app services are shared between the clusters right now. CLIProxyAPI used to
be exposed from homelab (`apps/cliproxyapi/service.yaml`, Tailscale hostname
`cliproxyapi-homelab`) and imported in Hetzner through an ExternalName stub in
`infrastructure/hetzner/configs/remote-homelab-stubs.yaml`; both were removed.

For a new shared service, export it with a Tailscale-annotated Service in the
source cluster and import it with an operator-managed ExternalName Service
(`tailscale.com/tailnet-fqdn` or `tailscale.com/tailnet-ip`) in the other.
Don't point one cluster at the other's pod IPs, because they change on restart.

The remaining selectorless EndpointSlice stubs are explicit low-level test
stubs, such as Kubernetes API reachability. Keep those separate from app
traffic.

## Rollout

```bash
nix develop

# Hetzner firewall: opens UDP 41641 for direct Tailscale connectivity.
source scripts/hetzner-env.sh
MY_IP=$(curl -fsS https://api.ipify.org)
tofu -chdir=terraform/hetzner apply -var "admin_cidrs=[\"${MY_IP}/32\"]"

# Homelab LXC: adds /dev/net/tun passthrough and restarts the container.
cd ansible
ansible-playbook site.yml --tags proxmox

# Configure both subnet routers and route-table overrides.
ansible-playbook site.yml --tags tailscale
ansible-playbook -i inventory/hetzner.yml hetzner.yml --tags tailscale
```

## Verification

```bash
cd ansible
ansible -i inventory/hosts.yml k3s_cluster -m shell -a 'test -c /dev/net/tun && tailscale status && ip route get 10.53.0.1'
ansible -i inventory/hetzner.yml hetzner_k3s_cluster -m shell -a 'test -c /dev/net/tun && tailscale status && ip route get 10.43.0.1'

ansible -i inventory/hosts.yml k3s_cluster -m shell -a 'tailscale ping -c 3 hetzner-k3s'
ansible -i inventory/hetzner.yml hetzner_k3s_cluster -m shell -a 'tailscale ping -c 3 homelab-k3s'
```

Operator service checks, for any shared Service you add later:

```bash
kubectl -n <namespace> get svc <service> -o yaml | yq '.status'
KUBECONFIG=kubeconfig-hetzner kubectl -n remote-homelab get svc <service> -o yaml | yq '.spec, .status'
```
