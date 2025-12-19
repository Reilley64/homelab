resource "docker_network" "media" {
  name = "media"
  driver = "bridge"
}

resource "docker_network" "postgres" {
  name = "postgres"
  driver = "bridge"
}
