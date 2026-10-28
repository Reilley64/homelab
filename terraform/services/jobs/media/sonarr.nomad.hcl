job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Two copies would run the same scheduled imports against one database,
    # so no canary.
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
        to           = 8989
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

    volume "downloads" {
      type   = "host"
      source = "downloads"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        ports = ["http"]
        volumes = [
          "/mnt/media:/mnt/media",
        ]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        SONARR__POSTGRES__USER = "${database_user}"
      }

      # toJSON quotes the password, so any character in it survives the env file.
      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          SONARR__POSTGRES__PASSWORD={{ .Data.data.database_password | toJSON }}
          {{ end -}}
          {{ range service "postgres" -}}
          SONARR__POSTGRES__HOST={{ .Address }}
          SONARR__POSTGRES__PORT={{ .Port }}
          {{ end -}}
        EOT
      }

      volume_mount {
        volume      = "${name}"
        destination = "/config"
      }

      volume_mount {
        volume      = "downloads"
        destination = "/downloads"
      }

      # Imports copy whole releases to the NAS, and that page cache is charged
      # to this task. Under heavy disk load the kernel can't reclaim it fast
      # enough, and a 1 GiB limit OOM-killed Radarr in the middle of 2160p
      # imports.
      resources {
        cpu        = 500
        memory     = 512
        memory_max = 4096
      }
    }
  }
}
