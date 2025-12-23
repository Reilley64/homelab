variable "name" {
  type = string
}

variable "image" {
  type = string
}

variable "capabilities" {
  type    = list(string)
  default = []
}

variable "port" {
  type    = number
  default = null
}

variable "ports" {
  type = list(object({
    internal_port = number
    external_port = number
  }))
  default = []
}

variable "networks" {
  type    = list(string)
  default = []
}

variable "forward" {
  type    = string
  default = null
}

variable "env" {
  type    = list(string)
  default = []
}

variable "devices" {
  type = list(object({
    container_path = string
    host_path      = string
  }))
  default = []
}

variable "volumes" {
  type = list(object({
    container_path = string
    host_path      = string
  }))
  default = []
}

variable "privileged" {
  type    = bool
  default = false
}

variable "command" {
  type    = list(string)
  default = []
}

variable "public" {
  type    = bool
  default = false
}

variable "cloudflare_zone_id" {
  type    = string
  default = null
}
