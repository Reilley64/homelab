job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # One copy owns the data directory, so no canary.
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

      port "http" {
        to           = 3200
        host_network = "internal"
      }

      port "otlp" {
        to           = 4317
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
        path     = "/ready"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    service {
      name     = "${service}-otlp"
      port     = "otlp"
      provider = "consul"

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    volume "tempo" {
      type   = "host"
      source = "tempo"
    }

    task "${name}" {
      driver = "docker"
      user   = "${user}"

      config {
        image = "${image}"
        ports = ["http", "otlp"]

        args = [
          "-config.file=/local/tempo.yml",
        ]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      template {
        destination = "local/tempo.yml"
        data        = ${jsonencode(config)}
      }

      volume_mount {
        volume      = "tempo"
        destination = "/var/tempo"
      }

      resources {
        cpu        = 200
        memory     = 128
        memory_max = 512
      }
    }
  }
}
