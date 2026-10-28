job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # SQLite allows one writer, so the old allocation stops first.
    update {
      max_parallel      = 1
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "2m"
      progress_deadline = "3m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 80
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
        path     = "/alive"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    volume "${name}" {
      type   = "host"
      source = "${name}"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        ports = ["http"]
      }

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
          ADMIN_TOKEN={{ .Data.data.admin_token }}
          {{ end -}}
        EOT
      }

      volume_mount {
        volume      = "${name}"
        destination = "/data"
      }

      resources {
        cpu        = 200
        memory     = 128
        memory_max = 512
      }
    }
  }
}
