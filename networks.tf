resource "docker_network" "postgres" {
  name = "postgres"
  driver = "bridge"
}

resource "docker_network" "torrents" {
  name = "torrents"
  driver = "bridge"
}
