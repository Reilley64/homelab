job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Two copies would share one SQLite database, so no canary.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "2m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 9696
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
        path     = "/ping"
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

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      volume_mount {
        volume      = "${name}"
        destination = "/config"
      }

      resources {
        cpu        = 200
        memory     = 384
        memory_max = 768
      }
    }
  }
}
