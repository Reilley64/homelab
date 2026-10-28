locals {
  route          = coalesce(var.route_name, var.name)
  hostname       = format("%s.%s", local.route, var.domain)
  local_hostname = format("%s.localdomain", local.route)

  base_labels = {
    "diun.enable"            = true
    "traefik.docker.network" = "traefik"
  }

  traefik_backend_label = var.url != null ? {
    (format("traefik.http.services.%s.loadbalancer.server.url", local.route)) = var.url
    } : var.port != null ? {
    (format("traefik.http.services.%s.loadbalancer.server.port", local.route)) = var.port
  } : {}

  traefik_public_labels = var.public ? {
    (format("traefik.http.routers.%s.rule", local.route))             = format("Host(`%s`)", local.hostname)
    (format("traefik.http.routers.%s.entrypoints", local.route))      = "websecure"
    (format("traefik.http.routers.%s.tls.certresolver", local.route)) = "myresolver"
    (format("traefik.http.routers.%s.service", local.route))          = local.route
  } : {}

  traefik_local_labels = length(local.traefik_backend_label) > 0 ? {
    (format("traefik.http.routers.%slocal.rule", local.route))        = format("Host(`%s`)", local.local_hostname)
    (format("traefik.http.routers.%slocal.entrypoints", local.route)) = "web"
    (format("traefik.http.routers.%slocal.service", local.route))     = local.route
  } : {}

  # Retries requests that reach the old container while it shuts down.
  rolling_labels = var.rolling == null ? {} : merge(
    { (format("traefik.http.middlewares.%s-retry.retry.attempts", local.route)) = "2" },
    var.public ? { (format("traefik.http.routers.%s.middlewares", local.route)) = format("%s-retry", local.route) } : {},
    length(local.traefik_local_labels) > 0 ? { (format("traefik.http.routers.%slocal.middlewares", local.route)) = format("%s-retry", local.route) } : {},
  )

  labels = merge(
    local.base_labels,
    local.traefik_backend_label,
    local.traefik_public_labels,
    local.traefik_local_labels,
    local.rolling_labels,
    var.labels
  )

  # Each replacement needs a new name, because the old container still runs
  # while the new one starts. This hash must cover every argument of
  # docker_container.rolling that forces a replacement.
  rolling_name = format("%s-%s", var.name, substr(nonsensitive(sha256(jsonencode([
    docker_image.image.image_id,
    local.labels,
    var.rolling,
    var.networks,
    var.ipv4_addresses,
    var.forward,
    var.ports,
    var.env,
    var.otel_resource_attributes,
    var.command,
    var.user,
    var.privileged,
    var.capabilities,
    var.cpus,
    var.memory,
    var.memory_swap,
    var.devices,
    var.volumes,
    var.uploads,
  ]))), 0, 8))

  container_name = var.rolling == null ? var.name : local.rolling_name

  env = length(var.otel_resource_attributes) == 0 ? var.env : concat(var.env, [
    format("OTEL_RESOURCE_ATTRIBUTES=%s", join(",", [
      for key, value in merge(var.otel_resource_attributes, { "container.name" = local.container_name }) :
      format("%s=%s", key, value)
    ])),
  ])
}

data "docker_registry_image" "image" {
  count = var.build == null ? 1 : 0

  name = var.image
}

resource "docker_image" "image" {
  name          = var.image
  pull_triggers = var.build == null ? [data.docker_registry_image.image[0].sha256_digest] : null
  triggers      = var.build == null ? null : var.build.triggers
  keep_locally  = true

  dynamic "build" {
    for_each = var.build == null ? [] : [var.build]
    content {
      context            = build.value.context
      dockerfile         = build.value.dockerfile
      use_legacy_builder = true
    }
  }
}

resource "docker_container" "container" {
  count = var.rolling == null ? 1 : 0

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
      name         = networks_advanced.value
      ipv4_address = lookup(var.ipv4_addresses, networks_advanced.value, null)
    }
  }

  dynamic "ports" {
    for_each = var.ports
    content {
      internal = ports.value.internal_port
      external = ports.value.external_port
    }
  }

  env         = local.env
  command     = var.command
  user        = var.user
  privileged  = var.privileged
  cpus        = var.cpus
  memory      = var.memory
  memory_swap = var.memory_swap

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

# The same container as docker_container.container, created before the old one
# is destroyed and checked for health before Terraform moves on. Traefik ignores
# a container until its healthcheck passes, so traffic moves over without a gap.
resource "docker_container" "rolling" {
  count = var.rolling == null ? 0 : 1

  name    = local.rolling_name
  image   = docker_image.image.image_id
  restart = "unless-stopped"
  wait    = true

  healthcheck {
    test           = var.rolling.healthcheck
    interval       = "30s"
    timeout        = "5s"
    retries        = 3
    start_period   = "1m0s"
    start_interval = "1s"
  }

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
      name         = networks_advanced.value
      ipv4_address = lookup(var.ipv4_addresses, networks_advanced.value, null)
      aliases      = [var.name]
    }
  }

  dynamic "ports" {
    for_each = var.ports
    content {
      internal = ports.value.internal_port
      external = ports.value.external_port
    }
  }

  env         = local.env
  command     = var.command
  user        = var.user
  privileged  = var.privileged
  cpus        = var.cpus
  memory      = var.memory
  memory_swap = var.memory_swap

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

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "dns" {
  count = var.public ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.route
  ttl     = 1
  type    = "CNAME"
  content = format("app.%s", var.domain)
  comment = "managed by terraform"
}

resource "unifi_dns_record" "local" {
  count = length(local.traefik_local_labels) > 0 || var.local_dns ? 1 : 0

  name        = local.local_hostname
  record_type = "A"
  value       = var.host_ip
}
