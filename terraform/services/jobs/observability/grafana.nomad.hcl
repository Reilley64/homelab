job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # SQLite in the data directory allows one writer, so no canary.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "5m"
    }

    # Consul drops the allocation before it stops, so Traefik and Prometheus
    # stop using it first.
    shutdown_delay = "5s"

    network {
      mode = "bridge"

      port "http" {
        to           = 3000
        host_network = "internal"
      }
    }

    service {
      name     = "${service}"
      port     = "http"
      provider = "consul"
      tags     = ${jsonencode(traefik_tags)}

      check {
        type     = "http"
        path     = "/api/health"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    volume "grafana" {
      type   = "host"
      source = "grafana"
    }

    task "${name}" {
      driver = "docker"
      user   = "${user}"

      config {
        image = "${image}"
        ports = ["http"]
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        GF_SERVER_ROOT_URL    = "http://grafana.localdomain"
        GF_PLUGINS_PREINSTALL = "marcusolsson-dynamictext-panel@6.3.0"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          GF_SECURITY_ADMIN_PASSWORD={{ .Data.data.admin_password }}
          {{ end -}}
        EOT
      }

      volume_mount {
        volume      = "grafana"
        destination = "/var/lib/grafana"
      }

      resources {
        cpu        = 300
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
