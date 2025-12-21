resource "docker_network" "torrents" {
  name = "torrents"
  driver = "bridge"
}
