job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Stateless, so a canary can run next to the old copy.
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
        to           = 9115
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
      tags     = ${jsonencode(concat(["metrics"], traefik_tags))}

      check {
        type     = "http"
        path     = "/-/healthy"
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

        args = [
          "--config.file=/local/blackbox.yml",
        ]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      template {
        destination = "local/blackbox.yml"
        data        = ${jsonencode(config)}
      }

      resources {
        cpu        = 100
        memory     = 64
        memory_max = 128
      }
    }
  }
}
