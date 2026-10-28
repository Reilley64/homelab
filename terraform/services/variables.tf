variable "domain" {
  type = string
}

variable "uid" {
  type = string
}

variable "gid" {
  type = string
}

variable "username" {
  type = string
}

variable "password" {
  type      = string
  sensitive = true
}

variable "discord_webhook" {
  type      = string
  sensitive = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "unifi_api_key" {
  type      = string
  sensitive = true
}

variable "jellyfin_api_key" {
  type      = string
  sensitive = true
}

variable "arcto_vaultwarden_admin_token" {
  type      = string
  sensitive = true
}

variable "radarr_api_key" {
  type      = string
  sensitive = true
}

variable "sonarr_api_key" {
  type      = string
  sensitive = true
}

variable "tabletop_signing_key" {
  type      = string
  sensitive = true
}

variable "nas_username" {
  type = string
}

variable "nas_password" {
  type      = string
  sensitive = true
}

variable "wireguard_private_key" {
  type      = string
  sensitive = true
}

variable "consul_metrics_token" {
  type        = string
  sensitive   = true
  description = "Secret of a Consul token with the prometheus policy from the platform root."
}
