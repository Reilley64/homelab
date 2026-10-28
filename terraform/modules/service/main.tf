locals {
  route          = coalesce(var.route_name, var.name)
  hostname       = format("%s.%s", local.route, var.domain)
  local_hostname = format("%s.localdomain", local.route)
  routed         = var.traefik || var.public

  traefik_local_tags = local.routed ? [
    "traefik.enable=true",
    format("traefik.http.routers.%slocal.rule=Host(`%s`)", local.route, local.local_hostname),
    format("traefik.http.routers.%slocal.entrypoints=web", local.route),
    format("traefik.http.routers.%slocal.service=%s", local.route, local.route),
  ] : []

  traefik_public_tags = var.public ? [
    format("traefik.http.routers.%s.rule=Host(`%s`)", local.route, local.hostname),
    format("traefik.http.routers.%s.entrypoints=websecure", local.route),
    format("traefik.http.routers.%s.tls.certresolver=myresolver", local.route),
    format("traefik.http.routers.%s.service=%s", local.route, local.route),
  ] : []

  image_tag = one(regexall(":([^:/@]+)$", var.image)[*][0])

  # Nomad fills in the allocation ID at runtime, hence the escaped interpolation.
  otel_resource_attributes = merge(
    {
      "service.namespace"   = var.namespace
      "service.instance.id" = "$${NOMAD_ALLOC_ID}"
    },
    local.image_tag == null ? {} : { "service.version" = local.image_tag },
    var.otel_resource_attributes,
  )

  env = merge(var.env, {
    OTEL_SERVICE_NAME = local.route
    OTEL_RESOURCE_ATTRIBUTES = join(",", [
      for key, value in local.otel_resource_attributes : format("%s=%s", key, value)
    ])
  })

  # The digest pins the image Nomad runs to what the tag points at during this
  # plan, so a new upstream digest changes the job and Nomad redeploys it.
  pinned_images = {
    for key, image in var.images :
    key => format("%s@%s", image, data.docker_registry_image.images[key].sha256_digest)
  }

  jobspec = templatefile(var.job_file, merge(var.job_vars, local.pinned_images, {
    name         = var.name
    namespace    = var.namespace
    service      = local.route
    image        = var.build == null ? format("%s@%s", var.image, data.docker_registry_image.image[0].sha256_digest) : docker_image.build[0].name
    traefik_tags = concat(local.traefik_local_tags, local.traefik_public_tags, var.traefik_tags)
    env          = local.env
  }))
}

data "docker_registry_image" "image" {
  count = var.build == null ? 1 : 0

  name = var.image
}

data "docker_registry_image" "images" {
  for_each = var.images

  name = each.value
}

resource "docker_image" "build" {
  count = var.build == null ? 0 : 1

  name         = var.image
  triggers     = var.build.triggers
  keep_locally = true

  build {
    context            = var.build.context
    dockerfile         = var.build.dockerfile
    label              = var.build.labels
    use_legacy_builder = true
  }
}

resource "nomad_job" "job" {
  jobspec = local.jobspec

  # Terraform waits for the deployment, so a failed canary fails the apply.
  detach = false

  # Removing a module call removes the job and its history, as removing a
  # container did.
  purge_on_destroy = true
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
  count = local.routed || var.local_dns ? 1 : 0

  name        = local.local_hostname
  record_type = "A"
  value       = var.host_ip
}
