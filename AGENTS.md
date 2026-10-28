# AGENTS.md

Guidance for coding agents working in this repository.

## What this is

A personal homelab managed with Terraform. The Docker provider connects over SSH to one host (`192.168.86.199`), and every service runs there as a container behind Traefik. Terraform also manages public DNS in Cloudflare, LAN DNS in UniFi, and Grafana's configuration.

The Terraform root is `terraform/services/`; run every Terraform command from there. Credentials and other sensitive values live in `terraform/services/.auto.tfvars`, which is gitignored. `variables.tf` lists the required inputs. State lives in the local `terraform/services/terraform.tfstate` file; there is no remote backend.

## How to work here

Every `terraform apply` changes services that are running and in use. Edit files and run `terraform fmt`, `terraform validate` and `terraform plan` freely. Ask the user before you run `terraform apply`, `terraform destroy`, a `terraform state` command, or any other action that deploys or changes the host. When you ask, summarize what the plan creates, changes and replaces.

Verify changes against the live system: read the plan, check the service in the browser, or query its API. Keep code tests out of this repository.

Deliver what was asked, at the scope intended. If a request looks mistaken or a better approach exists, say so in a sentence and carry on with the task as asked.

## Architecture

### Service module

Build every containerized service with `terraform/modules/service/`. It creates the Docker container, the Traefik routing labels, the DNS records and the network attachments together, so a service added any other way is missing its route or its DNS name.

- Public services get `{name}.reilley.dev` and a Cloudflare CNAME.
- LAN services get `{name}.localdomain` and a UniFi A record.

### File organization

Each service domain has its own `.tf` file, such as `media.tf`, `torrents.tf`, `tabletop.tf` and `observability.tf`. Put a new service in the matching file, or create a new file for a new domain.

### Networking

Each service domain has its own Docker network, such as `media_network` or `torrents_network`. Services that talk to each other must share a network, for example media apps and Postgres, or torrent clients and Gluetun. Traefik joins every network that exposes HTTP services.

### Conventions

- `main.tf` defines `TZ`, `PUID` and `PGID` in `local.shared_env`. Every service passes it into its `env` block.
- Persistent volumes mount from `/home/${var.username}/appdata/{service}/`.
- qBittorrent sends all traffic through the VPN with `network_mode = "container:${module.gluetun.id}"`.
- A service that needs a config file gets it through the service module's `uploads` variable, which writes the file into the container before it starts. Keep the file in `terraform/services/config/` (for example `prometheus.yml.tftpl`), because the host has no copy. Changing an uploaded file replaces the container.

### Observability

Prometheus scrapes Traefik and node-exporter directly. The stack has no Alloy or Loki. Traefik's per-router metrics measure traffic for every service, and they split public traffic (`{service}@docker`) from LAN traffic (`{service}local@docker`) without changes to the service.

The `grafana/grafana` provider in `observability.tf` manages Grafana's datasources, dashboards, contact points and alert rules. Make Grafana changes in Terraform, because the next apply reverts anything changed in the UI.

## External research

Use `ketch` for web pages, open source code and library docs. Every command accepts `--json`, and `ketch config` reports the active backends.

- `ketch search "query"` returns web results. Add `--scrape` for full page content, or `--multi` to query several backends and merge the rankings.
- `ketch scrape <url> [url...]` returns clean markdown for one or more URLs.
- `ketch extract` converts HTML you already have, for example `curl ... | ketch extract`. It does not fetch, cache or open a browser.
- `ketch code "query" --lang go` finds real open source code with repository and line context.
- `ketch docs "query" --library /org/repo` returns docs for a specific library version.
