variable "hcloud_token" {
  description = "Hetzner Cloud API token. Set with TF_VAR_hcloud_token; never commit it."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name prefix for Hetzner cluster resources."
  type        = string
  default     = "hetzner-k3s"
}

variable "server_name" {
  description = "Hetzner server name."
  type        = string
  default     = "hetzner-k3s-1"
}

variable "server_type" {
  description = "Hetzner Cloud server type. Keep compute small and put k3s local-path data on a separate volume."
  type        = string
  default     = "cx33"
}

variable "local_path_volume_size" {
  description = "Hetzner Volume size in GB for /var/lib/rancher/k3s/storage."
  type        = number
  default     = 100
}

variable "location" {
  description = "Hetzner location."
  type        = string
  default     = "fsn1"
}

variable "image" {
  description = "Server OS image."
  type        = string
  default     = "ubuntu-24.04"
}

variable "network_ip_range" {
  description = "Private Hetzner network range reserved for the cluster."
  type        = string
  default     = "10.80.0.0/16"
}

variable "network_subnet_ip_range" {
  description = "Private subnet range for Hetzner cluster nodes."
  type        = string
  default     = "10.80.0.0/24"
}

variable "ssh_public_key_path" {
  description = "SSH public key to install on the server."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH and the Kubernetes API. Must be supplied explicitly so future plans fail closed."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "Provide at least one admin CIDR, for example -var 'admin_cidrs=[\"203.0.113.10/32\"]'."
  }
}

variable "ansible_inventory_path" {
  description = "Where Terraform writes the generated Ansible inventory."
  type        = string
  default     = "../../ansible/inventory/hetzner.yml"
}
