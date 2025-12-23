locals {
  hostname       = "${var.name}.reilley.dev"
  local_hostname = "${var.name}.localdomain"

  base_labels = {
    "diun.enable"            = true
    "traefik.docker.network" = "traefik"
  }

  traefik_port_label = var.port != null ? {
    "traefik.http.services.${var.name}.loadbalancer.server.port" = var.port
  } : {}

  traefik_public_labels = var.public ? {
    "traefik.http.routers.${var.name}.rule"             = "Host(`${local.hostname}`)"
    "traefik.http.routers.${var.name}.entrypoints"      = "websecure"
    "traefik.http.routers.${var.name}.tls.certresolver" = "myresolver"
    "traefik.http.routers.${var.name}.service"          = var.name
  } : {}

  traefik_local_labels = {
    "traefik.http.routers.${var.name}local.rule"        = "Host(`${local.local_hostname}`)"
    "traefik.http.routers.${var.name}local.entrypoints" = "web"
    "traefik.http.routers.${var.name}local.service"     = var.name
  }

  labels = merge(
    local.base_labels,
    local.traefik_port_label,
    local.traefik_public_labels,
    local.traefik_local_labels
  )
}

resource "docker_image" "image" {
  name         = var.image
  keep_locally = false
}

resource "docker_container" "container" {
  image        = docker_image.image.image_id
  name         = var.name
  restart      = "unless-stopped"
  privileged   = var.privileged
  network_mode = var.forward
  env          = var.env
  command      = var.command

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

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }

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

  dynamic "volumes" {
    for_each = var.volumes
    content {
      container_path = volumes.value.container_path
      host_path      = volumes.value.host_path
      read_only      = false
    }
  }
}

resource "cloudflare_dns_record" "test" {
  count   = var.public ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.name
  ttl     = 1
  type    = "CNAME"
  content = "app.reilley.dev"
}
