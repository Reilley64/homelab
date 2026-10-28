job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
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
        to           = 8080
        host_network = "internal"
      }

      port "rc" {
        to           = 5572
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
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3
          grace = "30s"
        }
      }
    }

    # The remote control API can run any rclone operation, so it has no
    # Traefik route and stays on the internal network.
    service {
      name     = "${service}-rc"
      port     = "rc"
      provider = "consul"

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        ports = ["http", "rc"]

        args = [
          "serve",
          "s3",
          "nas:S3",
          "--addr=:8080",
          "--vfs-cache-mode=off",
          "--rc",
          "--rc-addr=:5572",
        ]
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        RCLONE_CONFIG_NAS_TYPE = "smb"
        RCLONE_CONFIG_NAS_HOST = "192.168.86.132"
        RCLONE_RC_USER         = "rc"
      }

      # rclone reads RCLONE_AUTH_KEY as CSV, one quoted "key,secret" pair per
      # client. Single quotes keep those double quotes in the value.
      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          RCLONE_CONFIG_NAS_USER={{ .Data.data.nas_username }}
          RCLONE_CONFIG_NAS_PASS={{ .Data.data.nas_password }}
          RCLONE_RC_PASS={{ .Data.data.rc_password }}
          RCLONE_AUTH_KEY='${join(",", [for client in s3_clients : format("\"{{ .Data.data.%s_access_key_id }},{{ .Data.data.%s_secret_access_key }}\"", client, client)])}'
          {{ end -}}
        EOT
      }

      resources {
        cpu        = 500
        memory     = 128
        memory_max = 512
      }
    }
  }
}
