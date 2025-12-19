resource "docker_network" "media" {
  name = "media"
  driver = "bridge"
}
