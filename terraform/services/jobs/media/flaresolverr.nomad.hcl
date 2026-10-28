job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # FlareSolverr keeps no state, so a canary can run next to the old copy.
    update {
      max_parallel      = 1
      canary            = 1
      auto_promote      = true
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "2m"
      progress_deadline = "3m"
    }

    network {
      mode = "bridge"

      port "http" {
        to           = 8191
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
        ports = ["http"]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1536
      }
    }
  }
}
