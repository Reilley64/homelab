job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Two copies would extract the same downloads. Unpackerr has no HTTP
    # port, so the deployment watches the task state.
    update {
      max_parallel     = 1
      auto_revert      = true
      health_check     = "task_states"
      min_healthy_time = "10s"
      healthy_deadline = "2m"
      progress_deadline = "3m"
    }

    network {
      mode = "bridge"
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
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        UN_LOG_FILE = "/logs/unpackerr.log"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          UN_RADARR_0_API_KEY={{ .Data.data.radarr_api_key }}
          UN_SONARR_0_API_KEY={{ .Data.data.sonarr_api_key }}
          {{ end -}}
          {{ range service "radarr" }}UN_RADARR_0_URL=http://{{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "sonarr" }}UN_SONARR_0_URL=http://{{ .Address }}:{{ .Port }}{{ end }}
        EOT
      }

      volume_mount {
        volume      = "${name}"
        destination = "/logs"
      }

      volume_mount {
        volume      = "downloads"
        destination = "/downloads"
      }

      resources {
        cpu        = 200
        memory     = 128
        memory_max = 512
      }
    }
  }
}
