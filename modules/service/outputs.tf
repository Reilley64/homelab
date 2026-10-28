output "id" {
  value = one(concat(docker_container.container[*].id, docker_container.rolling[*].id))
}
