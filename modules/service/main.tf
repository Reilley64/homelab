resource "docker_image" "image" {
  name = var.image
  keep_locally = false
}

resource "docker_container" "container" {
  image = docker_image.image.image_id
  name = var.name
  restart = "unless-stopped"
  privileged = var.privileged

  env = var.env

  capabilities {
    add = var.capabilities
  }

  dynamic "devices" {
    for_each = var.devices
    content {
      container_path = devices.value.container_path
      host_path = devices.value.host_path
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

  dynamic "volumes" {
    for_each = var.volumes
    content {
      container_path = volumes.value.container_path
      host_path      = volumes.value.host_path
    }
  }
}

data "caddy_server_route" "route" {
  match {
    host = ["${var.name}.reilley.dev", "${var.name}.local"]
  }

  dynamic "handle" {
    for_each = var.ports
    content {
      reverse_proxy {
        upstream {
          dial = handle.value.external_port
        }
      }
    }
  }
}
