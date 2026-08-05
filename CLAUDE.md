# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A personal homelab managed entirely with Terraform, using the Docker, Cloudflare and Grafana providers. All services run as Docker containers on a single host, with Traefik as the reverse proxy.

Credentials and sensitive values live in a `.auto.tfvars` file (gitignored). See `variables.tf` for required inputs.

## Architecture

### Module Pattern

All containerized services use the reusable `modules/service/` module. It handles:
- Docker container creation
- Traefik routing labels (public via `{name}.example.invalid` or local via `{name}.localdomain`)
- Cloudflare DNS CNAME records for public services
- Network attachments

When adding a new service, use this module rather than raw `docker_container` resources.

### File Organization

Services are grouped by domain into separate `.tf` files — `media.tf`, `torrents.tf`, `immich.tf`, `observability.tf`, etc. Keep new services in the appropriate file or create a new one for a distinct domain.

### Networking

Each service domain has its own Docker network (e.g., `media_network`, `torrents_network`). Services that need to talk to each other (e.g., media apps to Postgres, torrents to Gluetun VPN) must share a network. Traefik is attached to all networks that expose HTTP services.

### Key Patterns

- **Shared environment**: `TZ`, `PUID`, `PGID` are defined as locals in `main.tf` and injected into every service's `env` block.
- **App data**: All persistent volumes mount to `/home/${var.username}/appdata/{service}/`.
- **VPN routing**: qBittorrent uses `network_mode = "container:${module.gluetun.id}"` to route all traffic through the Gluetun container.
- **Config files**: Services needing a config file pass it through the service module's `uploads` variable, which writes it into the container before start. Config lives in this repo (e.g. `observability/prometheus.yml`) — never assume a file exists on the host. Changing an uploaded file replaces the container.
- **Observability**: Prometheus scrapes Traefik and node-exporter directly; there is no Alloy or Loki. Traefik's per-router metrics are the traffic source for every service, so public traffic (`{service}@docker`) and LAN traffic (`{service}local@docker`) are separable without touching the service itself. Grafana's datasources, dashboards, contact points and alert rules are all managed by the `grafana/grafana` Terraform provider in `observability.tf` — configure Grafana in Terraform, not in the UI, or the next apply will revert it.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.
