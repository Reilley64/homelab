job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Diun locks its bbolt database, so two copies cannot run.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "2m"
    }

    network {
      mode = "bridge"
    }

    volume "${name}" {
      type   = "host"
      source = "${name}"
    }

    task "${name}" {
      driver = "docker"

      config {
        image = "${image}"
        args  = ["serve"]
      }

      # The task's workload identity token, with the ACL policy that the
      # platform root attaches to this job, reads every job through the Task
      # API socket. No long-lived Nomad token is needed.
      identity {
        env = true
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        DIUN_WATCH_WORKERS                  = "20"
        DIUN_WATCH_SCHEDULE                 = "0 */6 * * *"
        DIUN_WATCH_JITTER                   = "30s"
        DIUN_PROVIDERS_NOMAD                = "true"
        DIUN_PROVIDERS_NOMAD_WATCHBYDEFAULT = "true"
        NOMAD_ADDR                          = "unix://$${NOMAD_SECRETS_DIR}/api.sock"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          DIUN_NOTIF_DISCORD_WEBHOOKURL={{ .Data.data.discord_webhook }}
          {{ end -}}
        EOT
      }

      volume_mount {
        volume      = "${name}"
        destination = "/data"
      }

      resources {
        cpu        = 200
        memory     = 64
        memory_max = 256
      }
    }
  }
}
