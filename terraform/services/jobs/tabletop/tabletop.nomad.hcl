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
      progress_deadline = "3m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 3000
        host_network = "internal"
      }
    }

    # Consul drops the old allocation before it stops, so Traefik stops
    # sending it requests first.
    shutdown_delay = "5s"

    service {
      name     = "${service}"
      port     = "http"
      provider = "consul"
      tags     = ${jsonencode(traefik_tags)}

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        # Terraform builds the image on the host. There is nothing to pull.
        force_pull = false
        ports      = ["http"]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        ENVIRONMENT                 = "production"
        PUBLIC_URL                  = "${public_url}"
        S3__BUCKET                  = "tabletop"
        S3__REGION                  = "us-east-1"
        RCLONE__USER                = "rc"
        RCLONE__REMOTE              = "nas:S3"
        OTEL_EXPORTER_OTLP_PROTOCOL = "grpc"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          DATABASE_URL=postgresql://${database_user}:{{ .Data.data.database_password | urlquery }}@{{ range service "postgres" }}{{ .Address }}:{{ .Port }}{{ end }}/tabletop
          PLAYER_PASSWORD={{ .Data.data.player_password }}
          SIGNING_KEY={{ .Data.data.signing_key }}
          S3__ACCESS_KEY_ID={{ .Data.data.s3_access_key_id }}
          S3__SECRET_ACCESS_KEY={{ .Data.data.s3_secret_access_key }}
          RCLONE__PASSWORD={{ .Data.data.rclone_password }}
          {{ end -}}
          {{ range service "s3" }}S3__ENDPOINT=http://{{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "s3-rc" }}RCLONE__URL=http://{{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "alloy-otlp" }}OTEL_EXPORTER_OTLP_ENDPOINT=http://{{ .Address }}:{{ .Port }}{{ end }}
        EOT
      }

      resources {
        cpu        = 200
        memory     = 64
        memory_max = 256
      }
    }
  }
}
