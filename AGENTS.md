# AGENTS.md

Guidance for coding agents working in this repository.

## What this is

A personal homelab on one Gentoo host, `homelab-1` (`192.168.86.199`). Consul, Vault and Nomad run on the host as systemd services, each a one-node cluster with TLS and ACLs. Every service runs as a Nomad job behind Traefik.

| Path | Owns |
|---|---|
| `ansible/` | The host: packages, mounts, node_exporter, backups, the CA and the Consul, Vault and Nomad agents |
| `overlay/` | The Gentoo overlay with the `consul-bin`, `vault-bin` and `nomad-bin` ebuilds |
| `terraform/platform/` | Consul, Vault and Nomad objects: ACL policies, namespaces, auth methods, the KMS auto-unseal key |
| `terraform/services/` | The Nomad jobs, Cloudflare and UniFi DNS, Home Assistant's Consul registration and Grafana's configuration |
| `terraform/modules/service/` | One service: its Nomad job, Traefik tags and DNS records |
| `observability/` | `observability-agent`, a Go program that attributes Jellyfin egress to users. Built on the host |

Each Terraform root keeps its state in a local `terraform.tfstate`. `terraform/services/.auto.tfvars` holds the provider credentials. Both are gitignored.

`docs/` is gitignored and lives only in the main checkout. Read `docs/adr/` before you change a decision it records. Use `docs/runbooks/` to rebuild the control plane or recover the host.

## How to work here

Every apply changes services that are running and in use. Run these freely:

- `terraform fmt`, `terraform validate` and `terraform plan`
- `ansible-lint` and `ansible-playbook playbooks/site.yml --check --diff`
- read-only `nomad`, `consul` and `vault` commands
- `go vet ./...` and `go test ./...` in `observability/`

Ask the user before anything that changes the host or a cluster: `terraform apply` or `destroy`, a `terraform state` command, `ansible-playbook` without `--check`, `nomad job run`, `stop` or `restart`, Vault writes, or root commands over ssh. When you ask, summarize what the plan or check run creates, changes and replaces.

Verify changes against the live system: read the plan, check the service in the browser, or query its API. Do not add tests for Terraform or Ansible. The Go agent keeps its unit tests.

Deliver what was asked, at the scope intended. If a request looks mistaken or a better approach exists, say so in a sentence and carry on with the task as asked.

### Secrets

- Plan output, state and `.auto.tfvars` hold secret values. Grep plans for resource lines; never print them whole.
- Never trace shell scripts (`set -x`, `bash -x`) that touch secrets.
- Never commit plan files or state copies. `.gitignore` covers `*.tfplan` and `*.tfstate.*`.

### Running the tools

The APIs listen on the host with certificates from the homelab CA at `~/.homelab/pki/ca.crt`: Consul on `8501`, Vault on `8200` and Nomad on `4646`. Set `NOMAD_ADDR`, `CONSUL_HTTP_ADDR` and `VAULT_ADDR` with `https://`, the matching `*_CACERT` variables, and a token for each. The providers read the same variables, so no token reaches Terraform state. If you can't reach the LAN directly, open an ssh tunnel to those ports on `127.0.0.1`.

Ansible runs from `ansible/`. Install its collections with `ansible-galaxy collection install -r requirements.yml`.

## Services

Build every service with `modules/service/`. A module call's `name` is the job name, the Consul service, the Traefik router, the hostname label and the appdata volume name.

- The job file is `terraform/services/jobs/{namespace}/{name}.nomad.hcl`, rendered with `templatefile`. The module passes `name`, `namespace`, `service`, `image`, `traefik_tags` and `env`, plus anything in `job_vars`.
- `traefik = true` routes `{name}.localdomain` through Traefik and creates a UniFi A record.
- `public = true` also routes `{name}.reilley.dev` with a Let's Encrypt certificate and creates a Cloudflare CNAME.
- Put a service in the `.tf` file for its namespace, such as `media.tf` or `observability.tf`.

### Images

Images keep their tags, mostly `:latest`. The module pins each pulled image to its tag's current digest at plan time. When diun reports a new image, `terraform apply` redeploys the job. `observability-agent` and `tabletop` are built on the host through the Docker provider instead.

### Deployments

Terraform waits for each deployment, so a failed deployment fails the apply. A job that can run two copies at once deploys a canary with `auto_revert`. A job with static ports or a single-writer data directory stops the old copy first. Set `progress_deadline` one minute past `healthy_deadline`.

### Networking

- Groups use bridge networking, with ports on the `internal` host network (`10.91.0.1`). Traefik, Postgres, Piper and the qBittorrent UI also listen on the LAN.
- Tasks find other services through Consul in `template` blocks (`range service "postgres"`). A task with such a template needs an empty `consul {}` block.
- gluetun and qBittorrent are one group in the `torrents` job and share its network namespace. gluetun's firewall is qBittorrent's kill switch, so qBittorrent must never get a network of its own.

### Conventions

- Pass `local.shared_env` (`TZ`, `PUID` and `PGID`) as `env`.
- Persistent data lives in `/home/reilley/appdata/{service}/` and reaches a job as a Nomad host volume. Add the folder to `nomad_appdata_volumes` in `ansible/roles/nomad/defaults/main.yml` and run Ansible before the job uses it.
- Secrets live in Vault at `kv/{namespace}/{job}`. A task reads them with `vault {}` and a `template` block, never through `job_vars`.
- Config files live in `terraform/services/config/`. Pass a file's contents through `job_vars` into a `template` block.

## Observability

- Prometheus discovers Nomad services tagged `metrics` through Consul. It also scrapes node_exporter (a host service), Consul, Nomad, Vault and the blackbox probes of the public services.
- Alloy ships Jellyfin's log files to Loki. It also receives OTLP from services such as tabletop and passes metrics to Prometheus, logs to Loki and traces to Tempo. The module sets each task's OpenTelemetry service name and resource attributes.
- The `grafana/grafana` provider in `observability.tf` manages Grafana's data sources, dashboards, contact points and alert rules. Make Grafana changes in Terraform, because the next apply reverts anything changed in the UI.

## Backups

The Ansible `backups` role runs restic at 03:30 to the NAS and to S3. Postgres dumps come from the Nomad periodic job `ops/postgres-dump` at 03:00. The script copies SQLite databases and snapshots Consul, Vault and Nomad. A new SQLite database needs an entry in `backups_sqlite_databases` and an exclude for its live files.

## External research

Use `ketch` for web pages, open source code and library docs. Every command accepts `--json`, and `ketch config` reports the active backends.

- `ketch search "query"` returns web results. Add `--scrape` for full page content, or `--multi` to query several backends and merge the rankings.
- `ketch scrape <url> [url...]` returns clean markdown for one or more URLs.
- `ketch extract` converts HTML you already have, for example `curl ... | ketch extract`. It does not fetch, cache or open a browser.
- `ketch code "query" --lang go` finds real open source code with repository and line context.
- `ketch docs "query" --library /org/repo` returns docs for a specific library version.
