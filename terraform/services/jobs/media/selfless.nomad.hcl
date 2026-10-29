job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    update {
      max_parallel      = 1
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "5m"
      progress_deadline = "6m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 8080
        host_network = "internal"
      }
    }

    shutdown_delay = "5s"

    service {
      name     = "${service}"
      port     = "http"
      provider = "consul"
      tags     = ${jsonencode(traefik_tags)}

      check {
        name     = "readiness"
        type     = "http"
        path     = "/actuator/health/readiness/v1"
        interval = "10s"
        timeout  = "2s"
      }

      check {
        name     = "liveness"
        type     = "http"
        path     = "/actuator/health/liveness/v1"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "5m"
        }
      }
    }

    task "${name}" {
      driver = "docker"

      kill_timeout = "45s"

      config {
        image     = "${image}"
        ports     = ["http"]
        group_add = ["${render_gid}"]

        devices = [
          {
            host_path      = "/dev/dri/renderD128"
            container_path = "/dev/dri/renderD128"
          },
        ]

        volumes = [
          "/mnt/media:/mnt/media:ro",
        ]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          DATABASE__URL=postgresql://${name}:{{ .Data.data.database_password | urlquery }}@{{ range service "postgres" }}{{ .Address }}:{{ .Port }}{{ end }}/${name}
          {{ end -}}
          {{ range service "alloy-otlp" }}OTEL_EXPORTER_OTLP_ENDPOINT=http://{{ .Address }}:{{ .Port }}{{ end }}
        EOT
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 1024
      }
    }
  }
}
