output "id" {
  value = docker_container.container.id
}

output "caddy_route" {
  value = data.caddy_server_route.route
}
