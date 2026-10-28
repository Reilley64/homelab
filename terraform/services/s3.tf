locals {
  s3_clients = toset(["tabletop"])
}

resource "docker_network" "s3" {
  name   = "s3"
  driver = "bridge"
}

module "s3" {
  source = "../modules/service"

  domain             = var.domain
  name               = "s3"
  image              = "rclone/rclone:1.75.2"
  port               = 8080
  public             = true
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.s3.id, docker_network.traefik.id]

  env = concat(local.shared_env, [
    "RCLONE_CONFIG_NAS_TYPE=smb",
    "RCLONE_CONFIG_NAS_HOST=192.168.86.132",
    format("RCLONE_CONFIG_NAS_USER=%s", var.nas_username),
    format("RCLONE_CONFIG_NAS_PASS=%s", var.nas_password),
    format("RCLONE_AUTH_KEY=%s", join(",", [
      for client in local.s3_clients :
      format("\"%s,%s\"", random_password.s3_access_key[client].result, random_password.s3_secret_key[client].result)
    ])),
    "RCLONE_RC_USER=rc",
    format("RCLONE_RC_PASS=%s", random_password.s3_rc_password.result),
  ])

  command = [
    "serve",
    "s3",
    "nas:S3",
    "--addr=:8080",
    "--vfs-cache-mode=off",
    "--rc",
    "--rc-addr=:5572",
  ]
}

# The remote control API on port 5572 has no route through Traefik; containers on
# the s3 network reach it at http://s3:5572. It can run any rclone operation.
resource "random_password" "s3_rc_password" {
  length  = 40
  special = false
}

resource "random_password" "s3_access_key" {
  for_each = local.s3_clients

  length  = 20
  special = false
  lower   = false
}

resource "random_password" "s3_secret_key" {
  for_each = local.s3_clients

  length  = 40
  special = false
}
