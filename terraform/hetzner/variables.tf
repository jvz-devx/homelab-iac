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
  description = "Hetzner Cloud server type. cx33 gives a small but realistic 4 vCPU / 8 GB baseline for k3s."
  type        = string
  default     = "cx33"
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
  description = "CIDRs allowed to reach SSH and the Kubernetes API. Tighten this after first bootstrap."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "ansible_inventory_path" {
  description = "Where Terraform writes the generated Ansible inventory."
  type        = string
  default     = "../../ansible/inventory/hetzner.yml"
}
