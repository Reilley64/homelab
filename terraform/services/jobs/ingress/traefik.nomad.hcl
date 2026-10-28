job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Static ports mean two copies cannot run at once, so no canary.
    update {
      max_parallel      = 1
      auto_revert       = true
      min_healthy_time  = "10s"
      healthy_deadline  = "2m"
      progress_deadline = "3m"
    }

    network {
      mode = "host"

      port "web" {
        static       = 80
        host_network = "lan"
      }

      port "websecure" {
        static       = 443
        host_network = "lan"
      }

      port "traefik" {
        static       = 4040
        host_network = "lan"
      }
    }

    service {
      name     = "${service}"
      port     = "traefik"
      provider = "consul"
      tags     = ${jsonencode(concat(["metrics"], traefik_tags))}

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

    volume "letsencrypt" {
      type   = "host"
      source = "letsencrypt"
    }

    volume "traefik-log" {
      type   = "host"
      source = "traefik-log"
    }

    task "${name}" {
      driver = "docker"

      config {
        image        = "${image}"
        network_mode = "host"

        args = [
          "--api.insecure=true",
          "--ping=true",
          "--providers.consulcatalog=true",
          "--providers.consulcatalog.exposedByDefault=false",
          "--providers.consulcatalog.watch=true",
          "--providers.consulcatalog.endpoint.address=127.0.0.1:8501",
          "--providers.consulcatalog.endpoint.scheme=https",
          "--providers.consulcatalog.endpoint.tls.ca=/secrets/consul-ca.pem",
          "--metrics.prometheus=true",
          "--metrics.prometheus.addRoutersLabels=true",
          "--accesslog=true",
          "--accesslog.filepath=/var/log/traefik/access.json",
          "--accesslog.format=json",
          "--accesslog.fields.defaultmode=drop",
          "--accesslog.fields.names.StartUTC=keep",
          "--accesslog.fields.names.RouterName=keep",
          "--accesslog.fields.names.ClientHost=keep",
          "--accesslog.fields.names.DownstreamContentSize=keep",
          "--accesslog.fields.names.DownstreamStatus=keep",
          "--accesslog.fields.headers.defaultmode=drop",
          "--accesslog.fields.queryparameters.defaultmode=drop",
          "--entrypoints.web.address=:80",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.traefik.address=:4040",
          "--certificatesresolvers.myresolver.acme.tlschallenge=true",
          "--certificatesresolvers.myresolver.acme.email=${acme_email}",
          "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json",
        ]
      }

      # Nomad logs in to Consul with the task's workload identity and writes
      # the token to secrets/consul_token, so Traefik starts without Vault.
      consul {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        # Traefik has no flag for a token file. Its Consul API client reads
        # this variable.
        CONSUL_HTTP_TOKEN_FILE = "/secrets/consul_token"
      }

      template {
        destination = "secrets/consul-ca.pem"
        data        = ${jsonencode(consul_ca)}
      }

      volume_mount {
        volume      = "letsencrypt"
        destination = "/letsencrypt"
      }

      volume_mount {
        volume      = "traefik-log"
        destination = "/var/log/traefik"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
