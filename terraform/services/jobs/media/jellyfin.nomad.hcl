job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Jellyfin writes SQLite, so two copies must not run at once.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "5m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 8096
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

        # A database migration after an image bump can take minutes, and a
        # restart in the middle of one can leave the database half migrated.
        check_restart {
          limit = 3
          grace = "5m"
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

        # QSV transcoding.
        devices = [
          {
            host_path      = "/dev/dri"
            container_path = "/dev/dri"
          },
        ]

        # The rendered logging.json shadows the copy in appdata, so the repo
        # stays the only source for it.
        volumes = [
          "/mnt/media:/mnt/media",
          "local/logging.json:/config/logging.json:ro",
        ]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      template {
        destination = "local/logging.json"
        data        = ${jsonencode(logging_json)}
      }

      volume_mount {
        volume      = "${name}"
        destination = "/config"
      }

      resources {
        cpu        = 2000
        memory     = 1024
        memory_max = 4096
      }
    }
  }
}
