job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Home Assistant connects to the static LAN port, so no canary.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "5m"
      progress_deadline = "6m"
    }

    network {
      mode = "bridge"

      port "wyoming" {
        static       = 10200
        to           = 10200
        host_network = "lan"
      }
    }

    service {
      name     = "${service}"
      port     = "wyoming"
      provider = "consul"
      tags     = ${jsonencode(traefik_tags)}

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "2m"
        }
      }
    }

    volume "piper" {
      type   = "host"
      source = "piper"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        ports = ["wyoming"]
        args  = ["--voice=en_US-lessac-medium"]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      volume_mount {
        volume      = "piper"
        destination = "/data"
      }

      resources {
        cpu        = 1000
        memory     = 128
        memory_max = 1024
      }
    }
  }
}
