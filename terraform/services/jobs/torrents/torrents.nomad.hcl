job "${name}" {
  namespace   = "${namespace}"
  datacenters = ["homelab"]
  type        = "service"

  group "${name}" {
    # Port 8080 is static, and two clients with the same torrents would send
    # duplicate announces, so the old allocation stops before the new one.
    update {
      max_parallel     = 1
      auto_revert      = true
      min_healthy_time = "10s"
      healthy_deadline = "5m"
      progress_deadline = "6m"
    }

    # Every task in the group shares this network namespace, as
    # network_mode = "container:gluetun" did. Gluetun's firewall in this
    # namespace is the kill switch for qBittorrent. qBittorrent must never get
    # a network of its own.
    network {
      mode = "bridge"

      # Gluetun accepts input to its own subnet from any address, so the UI
      # needs no FIREWALL_INPUT_PORTS entry, as today.
      port "webui" {
        static       = 8080
        to           = 8080
        host_network = "lan"
      }
    }

    # Consul drops the old allocation before it stops, so Traefik stops
    # sending it requests first.
    shutdown_delay = "5s"

    service {
      name     = "${service}"
      port     = "webui"
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

    volume "qbittorrent" {
      type   = "host"
      source = "qbittorrent"
    }

    volume "downloads" {
      type   = "host"
      source = "downloads"
    }

    task "gluetun" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image   = "${gluetun_image}"
        cap_add = ["net_admin"]

        devices = [
          {
            host_path      = "/dev/net/tun"
            container_path = "/dev/net/tun"
          },
        ]
      }

      vault {}

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        VPN_SERVICE_PROVIDER             = "protonvpn"
        VPN_TYPE                         = "wireguard"
        PORT_FORWARD_ONLY                = "on"
        VPN_PORT_FORWARDING              = "on"
        VPN_PORT_FORWARDING_UP_COMMAND   = "/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":{{PORT}},\\\"current_network_interface\\\":\\\"{{VPN_INTERFACE}}\\\",\\\"random_port\\\":false,\\\"upnp\\\":false}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'"
        VPN_PORT_FORWARDING_DOWN_COMMAND = "/bin/sh -c 'wget -O- --retry-connrefused --post-data \"json={\\\"listen_port\\\":0,\\\"current_network_interface\\\":\\\"lo\\\"}\" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'"
      }

      template {
        destination = "secrets/app.env"
        env         = true
        data        = <<-EOT
          {{ with secret "kv/data/${namespace}/${name}" -}}
          WIREGUARD_PRIVATE_KEY={{ .Data.data.wireguard_private_key }}
          {{ end -}}
        EOT
      }

      resources {
        cpu        = 200
        memory     = 128
        memory_max = 256
      }
    }

    # A sidecar only has to start, not be healthy, before the main task runs.
    # This task holds qBittorrent back until Gluetun's health server reports
    # the tunnel up.
    task "wait-for-vpn" {
      driver = "docker"

      lifecycle {
        hook = "prestart"
      }

      config {
        image   = "${wait_image}"
        command = "sh"
        args    = ["-c", "until wget -qO- http://127.0.0.1:9999; do sleep 2; done"]
      }

      resources {
        cpu        = 50
        memory     = 16
        memory_max = 32
      }
    }

    task "qbittorrent" {
      driver = "docker"

      config {
        image = "${image}"

        volumes = [
          "/mnt/media:/mnt/media",
          "/mnt/roms:/mnt/roms",
        ]
      }

      env {
%{ for key, value in env ~}
        ${key} = ${jsonencode(value)}
%{ endfor ~}
        WEBUI_PORT = "8080"
      }

      volume_mount {
        volume      = "qbittorrent"
        destination = "/config"
      }

      volume_mount {
        volume      = "downloads"
        destination = "/downloads"
      }

      resources {
        cpu        = 4000
        memory     = 1024
        memory_max = 8192
      }
    }
  }
}
