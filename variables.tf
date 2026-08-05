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

variable "wireguard_private_key" {
  type      = string
  sensitive = true
}
