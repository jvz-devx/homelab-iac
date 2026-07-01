locals {
  labels = {
    managed-by = "terraform"
    cluster    = var.cluster_name
  }
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.cluster_name}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = local.labels
}

resource "hcloud_firewall" "k3s" {
  name   = "${var.cluster_name}-firewall"
  labels = local.labels

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.admin_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.admin_cidrs
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "41641"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-net"
  ip_range = var.network_ip_range
  labels   = local.labels
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.network_subnet_ip_range
}

resource "hcloud_server" "k3s" {
  name        = var.server_name
  image       = var.image
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  firewall_ids = [
    hcloud_firewall.k3s.id,
  ]
  labels    = local.labels
  user_data = file("${path.module}/user-data.yaml")
}

resource "hcloud_server_network" "k3s" {
  server_id  = hcloud_server.k3s.id
  network_id = hcloud_network.cluster.id

  depends_on = [
    hcloud_network_subnet.cluster,
  ]
}

resource "hcloud_volume" "local_path" {
  name     = "${var.cluster_name}-localpath"
  size     = var.local_path_volume_size
  location = var.location
  format   = "ext4"
  labels   = local.labels
}

resource "hcloud_volume_attachment" "local_path" {
  volume_id = hcloud_volume.local_path.id
  server_id = hcloud_server.k3s.id
  automount = false
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/${var.ansible_inventory_path}"
  file_permission = "0644"
  content = yamlencode({
    all = {
      children = {
        hetzner_k3s_cluster = {
          children = {
            hetzner_master = {
              hosts = {
                (var.server_name) = {
                  ansible_host = hcloud_server.k3s.ipv4_address
                  ansible_user = "root"
                  k3s_role     = "server"
                }
              }
            }
          }
        }
      }
    }
  })
}
