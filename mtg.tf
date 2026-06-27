module "mtg" {
  source = "./modules/service"

  name               = "mtg"
  image              = "nginx:latest"
  public             = true
  port               = 80
  cloudflare_zone_id = data.cloudflare_zone.reilley_dev.id
  networks           = [docker_network.traefik.id]

  env = local.shared_env

  # autoindex serves the directory tree as-is; inlined so no config file needs to live on the host
  command = [
    "sh", "-c",
    "echo 'server { listen 80; root /usr/share/nginx/html; autoindex on; }' > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'",
  ]

  volumes = [
    {
      container_path = "/usr/share/nginx/html"
      host_path      = module.magic.target
    },
  ]
}
