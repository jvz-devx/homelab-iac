# Tailscale Cross-Cluster Routing

Host-level Tailscale subnet routers connect the homelab and Hetzner k3s
clusters without joining the Kubernetes control planes.

| Node | Hostname | Advertised routes | Exit node |
|---|---|---|---|
| Homelab | `homelab-k3s` | `10.42.0.0/16`, `10.43.0.0/16` | No |
| Hetzner | `hetzner-k3s` | `10.52.0.0/16`, `10.53.0.0/16` | Yes |

## Tailnet Policy

Route and exit-node approval should be configured before running the Ansible
role because Tailscale route auto-approval is not retroactive.

Merge this shape into the existing tailnet policy without removing current
ACLs, grants, users, or groups:

```json
{
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

# Configure both subnet routers.
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

After host routing works, add Kubernetes selectorless Service and EndpointSlice
stubs for the specific remote services that need stable in-cluster names.
