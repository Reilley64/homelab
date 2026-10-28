provider "docker" {
  host = format("ssh://%s@192.168.86.199", var.username)
}

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
