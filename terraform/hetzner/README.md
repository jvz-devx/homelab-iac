# Hetzner k3s Cluster

This Terraform stack creates one Hetzner Cloud VM, an SSH/API firewall, and an
Ansible inventory for the second k3s cluster.

```bash
nix develop
source scripts/hetzner-env.sh
tofu -chdir=terraform/hetzner init
tofu -chdir=terraform/hetzner apply
cd ansible
ansible-playbook -i inventory/hetzner.yml hetzner.yml
```

The token is read from `ansible/group_vars/all.sops.yml` by
`scripts/hetzner-env.sh`; do not create plaintext `*.tfvars` files containing
the token.
