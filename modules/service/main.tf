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
      add = var.capabilities
    }
  }

  dynamic "devices" {
    for_each = var.devices
    content {
      container_path = devices.value.container_path
      host_path      = devices.value.host_path
    }
  }

  labels {
    label = "glance.name"
    value = title("Jellyfin")
  }

  labels {
    label = "glance.url"
    value = "https://${var.name}.reilley.dev"
  }

  labels {
    label = "glance.icon"
    value = "si:${var.name}"
  }

  labels {
    label = "glance.hide"
    value = "false"
  }

  dynamic "labels" {
    for_each = var.public ? [1] : []
    content {
      label = "traefik.http.routers.${var.name}.rule"
      value = "Host(`${var.name}.reilley.dev`)"
    }
  }

  dynamic "labels" {
    for_each = var.public ? [1] : []
    content {
      label = "traefik.http.routers.${var.name}.entrypoints"
      value = "websecure"
    }
  }

  dynamic "labels" {
    for_each = var.public ? [1] : []
    content {
      label = "traefik.http.routers.${var.name}.tls.certresolver"
      value = "myresolver"
    }
  }

  dynamic "labels" {
    for_each = var.ports
    content {
      label = "traefik.http.services.${var.name}.loadbalancer.server.port"
      value = labels.value.internal_port
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
