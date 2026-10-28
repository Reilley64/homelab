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
