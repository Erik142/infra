# Instruct terraform to download the provider on `terraform init`
terraform {
  required_providers {
    xenorchestra = {
      source = "terra-farm/xenorchestra"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "3.3.1"
    }
    mikrotik = {
      source  = "ddelnano/mikrotik"
      version = "0.10.0"
    }
  }
}

variable "controllers_def" {
  type = object({
    name  = string
    count = number
  })
  default = {
    name  = "kube-controller"
    count = 3
  }
}

variable "workers_def" {
  type = object({
    name  = string
    count = number
  })
  default = {
    name  = "kube-worker"
    count = 4
  }
}

variable "mikrotik_config" {
  type = object({
    username = string
    password = string
    ip_addr  = string
    tls      = bool
    insecure = bool
  })
}

variable "xenorchestra_config" {
  type = object({
    hostname = string
    username = string
    password = string
    insecure = bool
  })
}

variable "dns_config" {
  type = object({
    server        = string
    key_name      = string
    key_algorithm = string
    key_secret    = string
    domain        = string
  })
}

variable "image_template" {
  type = string
}

# Configure the XenServer Provider
provider "xenorchestra" {
  # Must be ws or wss
  url      = format("wss://%s", var.xenorchestra_config.hostname) # Or set XOA_URL environment variable
  username = var.xenorchestra_config.username                     # Or set XOA_USER environment variable
  password = var.xenorchestra_config.password                     # Or set XOA_PASSWORD environment variable

  # This is false by default and
  # will disable ssl verification if true.
  # This is useful if your deployment uses
  # a self signed certificate but should be
  # used sparingly!
  insecure = var.xenorchestra_config.insecure # Or set XOA_INSECURE environment variable to any value
}

provider "dns" {
  update {
    server        = var.dns_config.server
    key_name      = var.dns_config.key_name
    key_algorithm = var.dns_config.key_algorithm
    key_secret    = var.dns_config.key_secret
  }
}

provider "mikrotik" {
  host     = format("%s:8728", var.mikrotik_config.ip_addr) # Or set MIKROTIK_HOST environment variable
  username = var.mikrotik_config.username                   # Or set MIKROTIK_USER environment variable
  password = var.mikrotik_config.password                   # Or set MIKROTIK_PASSWORD environment variable
  tls      = var.mikrotik_config.tls                        # Or set MIKROTIK_TLS environment variable
  insecure = var.mikrotik_config.insecure                   # Or set MIKROTIK_INSECURE environment variable
}

locals {
  controllers = flatten([
    for i in range(1, var.controllers_def.count + 1) : {
      index    = i - 1
      hostname = format("%s%02d", var.controllers_def.name, i)
    }
  ])

  workers = flatten([
    for i in range(1, var.workers_def.count + 1) : {
      index    = i - 1
      hostname = format("%s%02d", var.workers_def.name, i)
    }
  ])
}

data "xenorchestra_pool" "pool" {
  name_label = "Göteborg"
}

data "xenorchestra_template" "template" {
  name_label = var.image_template
}

data "xenorchestra_network" "net" {
  name_label = "Server Network"
}
data "xenorchestra_sr" "storage" {
  name_label = "Samsung Nvme 2TB"
}

resource "xenorchestra_cloud_config" "config_worker" {
  for_each = { for w in local.workers : "${w.index}" => w.hostname }
  name     = "Kubernetes worker cloud config"
  # Template the cloudinit if needed
  template = templatefile("cloud_config.tftpl", {
    hostname      = each.value
    domain        = var.dns_config.domain
    role          = "worker"
    tls_san       = ""
    control_plane = "[ ${format("\\\"%s\\\", %s", xenorchestra_vm.master.network[0].ipv4_addresses[0], join(", ", [for c in xenorchestra_vm.controller : format("\\\"%s\\\"", c.network[0].ipv4_addresses[0])]))}]"
    master_ip     = xenorchestra_vm.master.network[0].ipv4_addresses[0]
  })
}

resource "xenorchestra_cloud_config" "config_controller" {
  for_each = { for c in local.controllers : "${c.index}" => c.hostname }
  name     = "Kubernetes control plane cloud config"
  # Template the cloudinit if needed
  template = templatefile("cloud_config.tftpl", {
    hostname      = each.value
    domain        = var.dns_config.domain
    role          = "control-plane"
    tls_san       = format("%s,kubectl.%s", join(",", [for c in local.controllers : format("%s.%s", c.hostname, var.dns_config.domain)]), var.dns_config.domain)
    control_plane = "[]"
    master_ip     = xenorchestra_vm.master.network[0].ipv4_addresses[0]
  })
}

resource "xenorchestra_cloud_config" "config_master" {
  name = "Kubernetes control plane master cloud config"
  template = templatefile("cloud_config.tftpl", {
    hostname      = local.controllers[0].hostname
    domain        = var.dns_config.domain
    role          = "master"
    tls_san       = format("%s,kubectl.%s", join(",", [for c in local.controllers : format("%s.%s", c.hostname, var.dns_config.domain)]), var.dns_config.domain)
    control_plane = "[]"
    master_ip     = ""
  })
}

resource "xenorchestra_vm" "controller" {
  for_each         = { for c in slice(local.controllers, 1, var.controllers_def.count) : "${c.index}" => c.hostname }
  memory_max       = 8589934592
  cpus             = 4
  cloud_config     = xenorchestra_cloud_config.config_controller[each.key].template
  name_label       = each.value
  name_description = "This VM has been created with Terraform"
  template         = data.xenorchestra_template.template.id
  wait_for_ip      = true
  auto_poweron     = true

  # Prefer to run the VM on the primary pool instance
  affinity_host = data.xenorchestra_pool.pool.master
  network {
    network_id = data.xenorchestra_network.net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.storage.id
    name_label = each.value
    size       = 214748364800
  }

  tags = [
    "Production",
  ]

  timeouts {
    create = "5m"
  }
}

resource "xenorchestra_vm" "master" {
  memory_max       = 8589934592
  cpus             = 4
  cloud_config     = xenorchestra_cloud_config.config_master.template
  name_label       = local.controllers[0].hostname
  name_description = "This VM has been created with Terraform"
  template         = data.xenorchestra_template.template.id
  wait_for_ip      = true
  auto_poweron     = true

  # Prefer to run the VM on the primary pool instance
  affinity_host = data.xenorchestra_pool.pool.master
  network {
    network_id = data.xenorchestra_network.net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.storage.id
    name_label = local.controllers[0].hostname
    size       = 214748364800
  }

  tags = [
    "Production",
  ]

  timeouts {
    create = "5m"
  }
}

resource "xenorchestra_vm" "worker" {
  for_each         = { for w in local.workers : "${w.index}" => w.hostname }
  memory_max       = 4294967296
  cpus             = 4
  cloud_config     = xenorchestra_cloud_config.config_worker[each.key].template
  name_label       = each.value
  name_description = "This VM has been created with Terraform"
  template         = data.xenorchestra_template.template.id
  wait_for_ip      = true
  auto_poweron     = true

  # Prefer to run the VM on the primary pool instance
  affinity_host = data.xenorchestra_pool.pool.master
  network {
    network_id = data.xenorchestra_network.net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.storage.id
    name_label = each.value
    size       = 214748364800
  }

  tags = [
    "Production",
  ]

  timeouts {
    create = "5m"
  }
}

resource "dns_a_record_set" "control-plane" {
  for_each  = { for c in local.controllers : "${c.index}" => (c.index == 0 ? xenorchestra_vm.master : xenorchestra_vm.controller[c.index]) }
  zone      = format("%s.", var.dns_config.domain)
  name      = each.value.name_label
  addresses = each.value.ipv4_addresses
  ttl       = 5
}

resource "dns_cname_record" "control-plane" {
  for_each = { for c in local.controllers : c.index => c.hostname }
  zone     = format("%s.", var.dns_config.domain)
  name     = format("kubectl%02d", each.key + 1)
  cname    = format("%s.%s.", each.value, var.dns_config.domain)
  ttl      = 5
}

resource "mikrotik_dhcp_lease" "control-plane" {
  for_each   = { for c in local.controllers : "${c.index}" => (c.index == 0 ? xenorchestra_vm.master : xenorchestra_vm.controller[c.index]) }
  address    = each.value.ipv4_addresses[0]
  macaddress = upper(each.value.network[0].mac_address)
  comment    = "Created with Terraform"
  blocked    = "false"
  dynamic    = false
}

resource "mikrotik_dhcp_lease" "worker" {
  for_each   = { for c in local.workers : "${c.index}" => xenorchestra_vm.worker[c.index] }
  address    = each.value.ipv4_addresses[0]
  macaddress = upper(each.value.network[0].mac_address)
  comment    = "Created with Terraform"
  blocked    = "false"
  dynamic    = false
}
