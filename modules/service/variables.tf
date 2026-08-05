# Declaration order throughout this module and at every call site:
#   identity -> routing -> networking -> runtime -> host access

# --- identity ---

variable "name" {
  type = string
}

variable "image" {
  type = string
}

# --- routing ---

variable "route_name" {
  type        = string
  default     = null
  description = "Names the Traefik router, service and hostname when they shouldn't follow the container name — e.g. routing to a container that shares another's netns."
}

variable "port" {
  type        = number
  default     = null
  description = "Container port Traefik forwards to. Not var.ports, which publishes to the host."
}

variable "url" {
  type        = string
  default     = null
  description = "Static backend url, in place of var.port."
}

variable "public" {
  type    = bool
  default = false
}

variable "cloudflare_zone_id" {
  type    = string
  default = null
}

# --- networking ---

variable "networks" {
  type    = list(string)
  default = []
}

variable "forward" {
  type        = string
  default     = null
  description = "Container to share a network namespace with, as \"container:<id>\"."
}

variable "ports" {
  type = list(object({
    internal_port = number
    external_port = number
  }))
  default     = []
  description = "Ports published to the host. Not var.port, which is Traefik's backend port."
}

# --- runtime ---

variable "env" {
  type    = list(string)
  default = []
}

variable "command" {
  type    = list(string)
  default = []
}

variable "user" {
  type    = string
  default = null
}

variable "privileged" {
  type    = bool
  default = false
}

variable "capabilities" {
  type    = list(string)
  default = []
}

# --- host access ---

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
    read_only      = optional(bool, false)
  }))
  default = []
}

variable "uploads" {
  type = list(object({
    file    = string
    content = string
  }))
  default     = []
  description = "Files written into the container between create and start, so config can live in this repo instead of on the host. Changing content replaces the container."
}
