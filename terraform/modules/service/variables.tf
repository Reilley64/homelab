# Declaration order throughout this module and at every call site:
#   identity -> job -> routing -> telemetry

# --- identity ---

variable "name" {
  type        = string
  description = "The job name. Also the Consul service, Traefik router and hostname label unless route_name is set."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,57}[a-z0-9]$", var.name))
    error_message = "Service names are lowercase RFC 1123 labels: letters, digits and hyphens, starting with a letter. The limit is 59 characters, so the name still fits in a hostname label with the \"local\" router suffix."
  }
}

variable "namespace" {
  type = string
}

variable "image" {
  type        = string
  description = "A pulled image is pinned to the tag's current digest in the job. A built image runs by its local tag."
}

variable "images" {
  type        = map(string)
  default     = {}
  description = "Other pulled images the job uses, keyed by template variable name. Pinned to their digests like image."
}

variable "build" {
  type = object({
    context    = string
    dockerfile = optional(string, "Dockerfile")
    labels     = optional(map(string), {})
    triggers   = optional(map(string), {})
  })
  default     = null
  description = "Build this image on the host from a local context. The job then runs the local tag, which Nomad must not pull."
}

# --- job ---

variable "job_file" {
  type        = string
  description = "Path to jobs/{namespace}/{job}.nomad.hcl, rendered with templatefile."
}

variable "job_vars" {
  type        = any
  default     = {}
  description = "Extra template variables for the job file. Never secret values: tasks read those from Vault."
}

variable "env" {
  type        = map(string)
  default     = {}
  description = "Environment for every task, such as local.shared_env. The module adds the OpenTelemetry variables."
}

# --- routing ---

variable "domain" {
  type = string
}

variable "route_name" {
  type        = string
  default     = null
  description = "Names the Consul service, Traefik router and hostname when they can't follow the job name, e.g. the qbittorrent service in the torrents job."

  validation {
    condition     = var.route_name == null || can(regex("^[a-z][a-z0-9-]{0,57}[a-z0-9]$", var.route_name))
    error_message = "Route names follow the same rule as service names."
  }
}

variable "traefik" {
  type        = bool
  default     = false
  description = "Route {name}.localdomain to the service through Traefik. public implies it."
}

variable "public" {
  type        = bool
  default     = false
  description = "Also route {name}.{domain} through Traefik with a Let's Encrypt certificate, and create its Cloudflare record."
}

variable "cloudflare_zone_id" {
  type    = string
  default = null
}

variable "traefik_tags" {
  type        = list(string)
  default     = []
  description = "Extra Consul service tags for Traefik, such as routers and middlewares beyond the module's own."
}

variable "local_dns" {
  type        = bool
  default     = false
  description = "Force a {name}.localdomain record for a service reached directly on a LAN port rather than through Traefik."
}

variable "host_ip" {
  type        = string
  default     = "192.168.86.199"
  description = "Address the {name}.localdomain A record resolves to. Every service is fronted by Traefik on this host."
}
