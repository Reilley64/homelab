provider "docker" {}

locals {
  shared_env = [
    "TZ=Australia/Melbourne",
    "PGID=1000",
    "PUID=1000",
  ]
}

resource "docker_image" "alpine" {
  name         = "alpine:latest"
  keep_locally = false
}
