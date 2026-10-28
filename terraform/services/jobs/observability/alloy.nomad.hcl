job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Two copies would ship every log line twice and share one positions
    # file, so no canary.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "5m"
      progress_deadline = "6m"
    }

    # Consul drops the allocation before it stops, so Traefik and Prometheus
    # stop using it first.
    shutdown_delay = "5s"

    network {
      mode = "bridge"

      port "http" {
        to           = 12345
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
        path     = "/-/ready"
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

    volume "alloy" {
      type   = "host"
      source = "alloy"
    }

    volume "jellyfin-log" {
      type      = "host"
      source    = "jellyfin-log"
      read_only = true
    }

    task "${name}" {
      driver = "docker"
      user   = "${user}"

      config {
        image = "${image}"
        ports = ["http", "otlp"]

        args = [
          "run",
          "/local/config.alloy",
          "--storage.path=/alloy",
          "--server.http.listen-addr=0.0.0.0:12345",
        ]
      }

      consul {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
      }

      # Alloy's own stage.template blocks use {{ }}, so consul-template must
      # leave the file alone.
      template {
        destination     = "local/config.alloy"
        left_delimiter  = "[["
        right_delimiter = "]]"
        data            = ${jsonencode(config)}
      }

      template {
        destination = "local/endpoints.env"
        env         = true
        data        = <<-EOT
          {{ range service "loki" }}LOKI_ADDRESS={{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "prometheus" }}PROMETHEUS_ADDRESS={{ .Address }}:{{ .Port }}{{ end }}
          {{ range service "tempo-otlp" }}TEMPO_OTLP_ADDRESS={{ .Address }}:{{ .Port }}{{ end }}
        EOT
      }

      volume_mount {
        volume      = "alloy"
        destination = "/alloy"
      }

      volume_mount {
        volume      = "jellyfin-log"
        destination = "/logs"
        read_only   = true
      }

      resources {
        cpu        = 200
        memory     = 256
        memory_max = 512
      }
    }
  }
}
