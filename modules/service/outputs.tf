output "caddy_route" {
  value = data.caddy_server_route.route
}

output "local_caddy_route" {
  value = data.caddy_server_route.local_route
}
