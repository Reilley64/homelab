resource "docker_image" "image" {
  name         = var.image
  keep_locally = false
}

resource "docker_container" "container" {
  image   = docker_image.image.image_id
  name    = var.name
  restart = "unless-stopped"

  env = var.env

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

  networks_advanced {
    name = var.network
  }

  dynamic "ports" {
    for_each = var.ports
    content {
      internal = ports.value.internal_port
      external = ports.value.external_port
    }
  }

  dynamic "mounts" {
    for_each = var.volumes
    content {
      target = mounts.value.container_path
      source = mounts.value.host_path
      type   = "bind"

      bind_options {
        selinux = "Z"
      }
    }
  }
}

data "caddy_server_route" "route" {
  match {
    host = ["${var.name}.reilley.dev", "${var.name}.local"]
  }

  handle {
    reverse_proxy {
      upstream {
        dial = var.ports.0.external_port
      }
    }
  }
}
