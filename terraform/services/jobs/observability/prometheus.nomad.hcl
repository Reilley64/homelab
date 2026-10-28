job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # One copy owns the TSDB, so no canary.
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
        to           = 9090
        host_network = "internal"
      }
    }

    service {
      name     = "${service}"
      port     = "http"
      provider = "consul"
      tags     = ${jsonencode(concat(["metrics"], traefik_tags))}

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

    volume "prometheus" {
      type   = "host"
      source = "prometheus"
    }

    task "${name}" {
      driver = "docker"
      user   = "${user}"

      config {
        image = "${image}"
        ports = ["http"]

        args = [
          "--config.file=/local/prometheus.yml",
          "--storage.tsdb.path=/prometheus/data",
          "--storage.tsdb.retention.time=30d",
          "--web.enable-otlp-receiver",
        ]
      }

      consul {}
      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        # consul {} sets CONSUL_HTTP_TOKEN to the task's own token, which lacks
        # agent:read. Consul service discovery would send it instead of the
        # authorization header, and the Consul client reads this file first.
        CONSUL_HTTP_TOKEN_FILE = "/secrets/prometheus_consul_token"
      }

      # A moved blackbox exporter only needs a config reload.
      template {
        destination   = "local/prometheus.yml"
        change_mode   = "signal"
        change_signal = "SIGHUP"
        data          = ${jsonencode(config)}
      }

      template {
        destination = "local/ca.crt"
        data        = ${jsonencode(consul_ca)}
      }

      # Prometheus rereads credential files on every request, so a new token
      # needs no restart. Nomad writes the task's own Consul token, which
      # lacks agent:read, to secrets/consul_token, so this file needs
      # another name.
      template {
        destination = "secrets/prometheus_consul_token"
        change_mode = "noop"
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" }}{{ .Data.data.consul_token }}{{ end }}
        EOT
      }

      volume_mount {
        volume      = "prometheus"
        destination = "/prometheus"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 1024
      }
    }
  }
}
