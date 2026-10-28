job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    update {
      max_parallel     = 1
      canary           = 1
      auto_promote     = true
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "2m"
    }

    network {
      mode = "bridge"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        DOMAINS        = "${domains}"
        IP6_PROVIDER   = "none"
        RECORD_COMMENT = "managed by cloudflare-ddns"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          CLOUDFLARE_API_TOKEN={{ .Data.data.cloudflare_api_token }}
          {{ end -}}
        EOT
      }

      resources {
        cpu        = 50
        memory     = 32
        memory_max = 128
      }
    }
  }
}
