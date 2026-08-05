locals {
  route          = coalesce(var.route_name, var.name)
  hostname       = "${local.route}.example.invalid"
  local_hostname = "${local.route}.localdomain"

  base_labels = {
    "diun.enable"            = true
    "traefik.docker.network" = "traefik"
  }

  traefik_backend_label = var.url != null ? {
    "traefik.http.services.${local.route}.loadbalancer.server.url" = var.url
    } : var.port != null ? {
    "traefik.http.services.${local.route}.loadbalancer.server.port" = var.port
  } : {}

  traefik_public_labels = var.public ? {
    "traefik.http.routers.${local.route}.rule"             = "Host(`${local.hostname}`)"
    "traefik.http.routers.${local.route}.entrypoints"      = "websecure"
    "traefik.http.routers.${local.route}.tls.certresolver" = "myresolver"
    "traefik.http.routers.${local.route}.service"          = local.route
  } : {}

  traefik_local_labels = length(local.traefik_backend_label) > 0 ? {
    "traefik.http.routers.${local.route}local.rule"        = "Host(`${local.local_hostname}`)"
    "traefik.http.routers.${local.route}local.entrypoints" = "web"
    "traefik.http.routers.${local.route}local.service"     = local.route
  } : {}

  labels = merge(
    local.base_labels,
    local.traefik_backend_label,
    local.traefik_public_labels,
    local.traefik_local_labels
  )
}

data "docker_registry_image" "image" {
  name = var.image
}

resource "docker_image" "image" {
  name          = data.docker_registry_image.image.name
  pull_triggers = [data.docker_registry_image.image.sha256_digest]
  keep_locally  = false
}

resource "docker_container" "container" {
  name    = var.name
  image   = docker_image.image.image_id
  restart = "unless-stopped"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }

  network_mode = var.forward

  dynamic "networks_advanced" {
    for_each = var.networks
    content {
      name = networks_advanced.value
    }
  }

  dynamic "ports" {
    for_each = var.ports
    content {
      internal = ports.value.internal_port
      external = ports.value.external_port
    }
  }

  env        = var.env
  command    = var.command
  user       = var.user
  privileged = var.privileged

  dynamic "capabilities" {
    for_each = length(var.capabilities) > 0 ? [1] : []
    content {
      add  = var.capabilities
      drop = []
    }
  }

  dynamic "devices" {
    for_each = var.devices
    content {
      container_path = devices.value.container_path
      host_path      = devices.value.host_path
      permissions    = "rwm"
    }
  }

  dynamic "volumes" {
    for_each = var.volumes
    content {
      container_path = volumes.value.container_path
      host_path      = volumes.value.host_path
      read_only      = volumes.value.read_only
    }
  }

  dynamic "upload" {
    for_each = var.uploads
    content {
      file    = upload.value.file
      content = upload.value.content
    }
  }
}

resource "cloudflare_dns_record" "dns" {
  count = var.public ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.route
  ttl     = 1
  type    = "CNAME"
  content = "app.example.invalid"
  comment = "managed by terraform"
}

resource "unifi_dns_record" "local" {
  count = length(local.traefik_local_labels) > 0 ? 1 : 0

  name        = local.local_hostname
  record_type = "A"
  value       = var.host_ip
}
