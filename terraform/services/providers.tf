provider "docker" {
  host = format("ssh://%s@%s", var.username, local.host_address)
}

# Reads NOMAD_ADDR, NOMAD_TOKEN and NOMAD_CACERT from the environment, as in the
# platform root, so no token reaches a variable or the state.
provider "nomad" {}

# Reads CONSUL_HTTP_ADDR, CONSUL_HTTP_TOKEN and CONSUL_CACERT from the
# environment, like the nomad provider.
provider "consul" {}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "grafana" {
  url  = "http://grafana.localdomain"
  auth = format("admin:%s", var.password)
}

provider "unifi" {
  api_url = "https://192.168.86.1"
  api_key = var.unifi_api_key

  allow_insecure = true
}
