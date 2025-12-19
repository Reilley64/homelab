variable "name" {
  type = string
}

variable "image" {
  type = string
}

variable "capabilities" {
  type = list(string)
  default = []
}

variable "ports" {
  type = list(object({
    internal_port = number
    external_port = number
  }))
  default = []
}

variable "network" {
  type = string
}

variable "env" {
  type = list(string)
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
    host_path = string
  }))
  default = []
}
