job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Two copies must never write the same data directory, so no canary.
    update {
      max_parallel      = 1
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "2m"
      progress_deadline = "3m"
    }

    network {
      mode = "bridge"

      port "db" {
        static       = 5432
        to           = 5432
        host_network = "lan"
      }
    }

    service {
      name     = "${service}"
      port     = "db"
      provider = "consul"
      tags     = ${jsonencode(traefik_tags)}

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    volume "postgres" {
      type   = "host"
      source = "postgres"
    }

    task "${name}" {
      driver = "docker"

      # SIGINT is Postgres's fast shutdown, the image's stop signal. It still
      # writes a checkpoint, which can take a while.
      kill_signal  = "SIGINT"
      kill_timeout = "60s"

      config {
        image = "${image}"
        ports = ["db"]
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        POSTGRES_USER = "${database_user}"
      }

      # The image reads the password only when it initialises an empty data
      # directory.
      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          POSTGRES_PASSWORD={{ .Data.data.password }}
          {{ end -}}
        EOT
      }

      volume_mount {
        volume      = "postgres"
        destination = "/var/lib/postgresql/data"
      }

      resources {
        cpu        = 1000
        memory     = 512
        memory_max = 2048
      }
    }
  }
}
