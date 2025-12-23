variable "username" {
  type = string
}

variable "password" {
  type      = string
  sensitive = true
}

variable "diun_webhook" {
  type      = string
  sensitive = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}
