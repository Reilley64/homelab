locals {
  tabletop_repository = "/Users/reilley/Repositories/untitled"
  tabletop_hostname   = format("tabletop.%s", var.domain)
  tabletop_sources = sort([
    for source_path in setunion(
      fileset(local.tabletop_repository, "{Cargo.toml,Cargo.lock,Dockerfile}"),
      fileset(local.tabletop_repository, "src/**"),
      fileset(local.tabletop_repository, "crates/**"),
    ) :
    source_path if !strcontains(source_path, "node_modules") && !strcontains(source_path, "/target/")
  ])
  tabletop_source_hash = sha256(join("", [
    for source_path in local.tabletop_sources :
    format("%s:%s", source_path, filesha256(format("%s/%s", local.tabletop_repository, source_path)))
  ]))
  tabletop_image_tag = substr(local.tabletop_source_hash, 0, 12)
  tabletop_git       = format("%s/.git", local.tabletop_repository)
  tabletop_git_head  = trimspace(file(format("%s/HEAD", local.tabletop_git)))
  tabletop_git_ref   = trimprefix(local.tabletop_git_head, "ref: ")
  tabletop_commit = (
    local.tabletop_git_ref == local.tabletop_git_head ? local.tabletop_git_head :
    fileexists(format("%s/%s", local.tabletop_git, local.tabletop_git_ref)) ? trimspace(file(format("%s/%s", local.tabletop_git, local.tabletop_git_ref))) :
    regex(format("([0-9a-f]{40}) %s\\n", local.tabletop_git_ref), file(format("%s/packed-refs", local.tabletop_git)))[0]
  )
}

module "tabletop" {
  source = "../modules/service"

  domain             = var.domain
  name               = "tabletop"
  image              = format("tabletop:%s", local.tabletop_image_tag)
  port               = 3000
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.postgres.id, docker_network.s3.id, docker_network.traefik.id, docker_network.observability.id]

  build = {
    context = local.tabletop_repository
  }

  rolling = {
    healthcheck = ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/3000 && printf 'GET /health HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && head -n 1 <&3 | grep -q ' 200 '"]
  }

  env = concat(local.shared_env, [
    "ENVIRONMENT=production",
    format("DATABASE_URL=postgresql://%s:%s@postgres:5432/tabletop", urlencode(var.username), urlencode(var.password)),
    format("PUBLIC_URL=https://%s", local.tabletop_hostname),
    format("PLAYER_PASSWORD=%s", var.password),
    format("SIGNING_KEY=%s", var.tabletop_signing_key),
    "S3__ENDPOINT=http://s3:8080",
    "S3__BUCKET=tabletop",
    "S3__REGION=us-east-1",
    format("S3__ACCESS_KEY_ID=%s", random_password.s3_access_key["tabletop"].result),
    format("S3__SECRET_ACCESS_KEY=%s", random_password.s3_secret_key["tabletop"].result),
    "RCLONE__URL=http://s3:5572",
    "RCLONE__USER=rc",
    format("RCLONE__PASSWORD=%s", random_password.s3_rc_password.result),
    "RCLONE__REMOTE=nas:S3",
    "OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317",
    "OTEL_EXPORTER_OTLP_PROTOCOL=grpc",
  ])

  otel_resource_attributes = {
    "container.image.name"  = "tabletop"
    "container.image.tags"  = local.tabletop_image_tag
    "vcs.ref.head.revision" = local.tabletop_commit
  }

  labels = {
    "traefik.http.routers.tabletop-sign-in.rule"                        = format("Host(`%s`) && Method(`POST`) && (Path(`/authorize`) || Path(`/login`))", local.tabletop_hostname)
    "traefik.http.routers.tabletop-sign-in.entrypoints"                 = "websecure"
    "traefik.http.routers.tabletop-sign-in.tls.certresolver"            = "myresolver"
    "traefik.http.routers.tabletop-sign-in.service"                     = "tabletop"
    "traefik.http.routers.tabletop-sign-in.middlewares"                 = "tabletop-sign-in-limit,tabletop-retry"
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.average" = "5"
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.period"  = "1m"
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.burst"   = "5"
  }
}
