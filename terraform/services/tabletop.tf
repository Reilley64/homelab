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

  name      = "tabletop"
  namespace = "tabletop"
  image     = format("tabletop:%s", local.tabletop_image_tag)

  build = {
    context = local.tabletop_repository
    labels = {
      "org.opencontainers.image.revision" = local.tabletop_commit
      "org.opencontainers.image.version"  = local.tabletop_image_tag
    }
  }

  job_file = format("%s/jobs/tabletop/tabletop.nomad.hcl", path.module)
  job_vars = {
    public_url    = format("https://%s", local.tabletop_hostname)
    database_user = var.username
  }
  env = local.shared_env

  domain             = var.domain
  host_address       = local.host_address
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id

  traefik_tags = [
    format("traefik.http.routers.tabletop-sign-in.rule=Host(`%s`) && Method(`POST`) && (Path(`/authorize`) || Path(`/login`))", local.tabletop_hostname),
    "traefik.http.routers.tabletop-sign-in.entrypoints=websecure",
    "traefik.http.routers.tabletop-sign-in.tls.certresolver=myresolver",
    "traefik.http.routers.tabletop-sign-in.service=tabletop",
    "traefik.http.routers.tabletop-sign-in.middlewares=tabletop-sign-in-limit",
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.average=5",
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.period=1m",
    "traefik.http.middlewares.tabletop-sign-in-limit.ratelimit.burst=5",
  ]
}
