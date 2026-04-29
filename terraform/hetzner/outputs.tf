output "server_ipv4" {
  description = "Public IPv4 address of the Hetzner k3s node."
  value       = hcloud_server.k3s.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the Hetzner k3s node."
  value       = hcloud_server.k3s.ipv6_address
}

output "private_network_id" {
  description = "Hetzner private network ID attached to the k3s server."
  value       = hcloud_network.cluster.id
}

output "server_private_ipv4" {
  description = "Private IPv4 address of the Hetzner k3s node."
  value       = hcloud_server_network.k3s.ip
}

output "ansible_inventory_path" {
  description = "Generated Ansible inventory path."
  value       = local_file.ansible_inventory.filename
}
