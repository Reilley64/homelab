job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # One copy tails and rotates the Traefik access log and owns the
    # checkpoint, so no canary.
    update {
      max_parallel      = 1
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "5m"
      progress_deadline = "6m"
    }

    # Consul drops the allocation before it stops, so Traefik and Prometheus
    # stop using it first.
    shutdown_delay = "5s"

    network {
      mode = "bridge"

      port "metrics" {
        to           = 9101
        host_network = "internal"
      }
    }

    service {
      name     = "${service}"
      port     = "metrics"
      provider = "consul"
      tags     = ${jsonencode(concat(["metrics"], traefik_tags))}

      check {
        type     = "http"
        path     = "/metrics"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    volume "traefik-log" {
      type   = "host"
      source = "traefik-log"
    }

    volume "jellyfin-egress-exporter" {
      type   = "host"
      source = "jellyfin-egress-exporter"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        # Terraform builds the image on the host. There is nothing to pull.
        force_pull = false
        ports      = ["metrics"]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        ACCESS_LOG_PATH        = "/logs/access.json"
        CHECKPOINT_PATH        = "/state/checkpoint.json"
        MAPPING_TTL_SECONDS    = "600"
        SESSION_POLL_SECONDS   = "15"
        METRICS_PORT           = "9101"
        LOG_MAX_BYTES          = "104857600"
        LOG_COPIES             = "7"
        ROTATION_CHECK_SECONDS = "60"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          JELLYFIN_API_KEY={{ .Data.data.jellyfin_api_key }}
          {{ end -}}
          {{ range service "jellyfin" }}JELLYFIN_URL=http://{{ .Address }}:{{ .Port }}{{ end }}
        EOT
      }

      volume_mount {
        volume      = "traefik-log"
        destination = "/logs"
      }

      volume_mount {
        volume      = "jellyfin-egress-exporter"
        destination = "/state"
      }

      resources {
        cpu        = 100
        memory     = 32
        memory_max = 128
      }
    }
  }
}
