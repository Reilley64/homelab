# Jellyfin Egress Attribution by User

Date: 2026-08-09

## Goal

Extend the existing Jellyfin Grafana dashboard with public upload egress grouped by
Jellyfin username. The byte count must come from Traefik rather than a bitrate estimate.

Attribution is intentionally best-effort. When multiple Jellyfin users share a public
IP, traffic is assigned to whichever username the collector most recently observed for
that IP. Occasional assignment to the wrong user is an accepted tradeoff.

## Measurement Semantics

"Egress" means the HTTP response-body bytes Traefik reports in
`DownstreamContentSize`. It excludes request bytes, TCP/IP and TLS overhead, and LAN
traffic. This matches the semantics of the aggregate
`traefik_router_responses_bytes_total` metric already used by the dashboard.

Only access-log entries for the public `jellyfin@docker` router are counted. Requests
through `jellyfinlocal@docker` remain excluded.

## Considered Approaches

### 1. Session-aware egress exporter (selected)

Combine Traefik's exact per-request byte count with the username and remote endpoint
from Jellyfin's `/Sessions` API. A small collector performs the join at event time and
exports Prometheus counters labelled by username and client IP.

This adds a purpose-built service and a Jellyfin API key, but it produces durable,
queryable per-user counters and keeps Grafana queries simple.

### 2. Loki queries plus a current IP mapping

Ship Traefik access logs to Loki and join their IP totals to the current Jellyfin
sessions in Grafana. This avoids a custom metrics exporter, but Grafana cannot perform a
reliable historical join across the two data sources. A session disappearing would
also remove the username mapping for earlier traffic.

### 3. Bitrate multiplied by playback duration

Poll Jellyfin sessions and estimate bytes from stream bitrate and elapsed playback
time. This is easy to attribute to a username but is inaccurate for variable bitrate,
seeking, buffering, partial segments, and non-playback responses.

## Architecture

### Traefik access log

Enable Traefik's JSON access log and write it to a dedicated bind-mounted directory
under `/home/${var.username}/appdata/traefik/log/`.

The log configuration keeps only the fields required by the collector:

- request timestamp;
- `RouterName`;
- `ClientHost`;
- `DownstreamContentSize`;
- downstream status.

Headers and query parameters are dropped. In particular, authorization headers and
Jellyfin API tokens must never enter the log.

The existing Traefik aggregate metrics remain unchanged and act as the reconciliation
source. Access-log rotation uses a small service configured for bounded retention and
`copytruncate`, because Traefik otherwise keeps a file descriptor open across a rename.
The design accepts the tiny possibility of losing a line during truncation.

If the public route is later placed behind Cloudflare's proxy, the collector must use a
client address derived only from forwarding headers trusted from Cloudflare's published
networks. It must not trust arbitrary inbound `X-Forwarded-For` values. With the current
DNS-only route, `ClientHost` is the client address directly.

### Jellyfin egress exporter

Add a service through `modules/service`, not a raw `docker_container`. Its source and
configuration live in this repository and are uploaded into the container. It joins the
media network to reach Jellyfin and the observability network so Prometheus can scrape
it. It is not exposed through Traefik.

Every 15 seconds the exporter requests `http://jellyfin:8096/Sessions` with a Jellyfin
API key. For sessions with active playback it extracts:

- `UserName`;
- `RemoteEndPoint`;
- the session identifier for diagnostics.

Addresses are normalized before comparison: ports are removed, IPv6 brackets are
handled, and IPv4-mapped IPv6 addresses are converted to their IPv4 representation.
Each observation overwrites the cached username for that IP. A mapping remains usable
for 10 minutes after its last observation to cover session-reporting delays. After that,
traffic for the IP is assigned to `unknown`.

The exporter tails Traefik's access-log file. For every valid entry whose router is
exactly `jellyfin@docker`, it normalizes `ClientHost`, looks up the cached username, and
adds `DownstreamContentSize` to a counter. The primary metric is:

```text
jellyfin_user_egress_bytes_total{user="alice",client_ip="203.0.113.8"}
```

The IP label is deliberate: it makes questionable assignments visible and is expected
to have low cardinality in this homelab. Dashboard totals aggregate by `user`.

The exporter also exposes health counters for malformed log entries, Jellyfin API
failures, and unattributed bytes. It persists the access-log inode and offset in
`/home/${var.username}/appdata/jellyfin-egress-exporter/`. On restart it resumes from the
checkpoint and catches up on retained log data. If no checkpoint exists, it starts at
the end of the current file rather than replaying all historical traffic.

Prometheus handles exporter counter resets normally, so metric totals do not need local
persistence. The file checkpoint is updated only after the corresponding counter has
been advanced, with duplicate processing on a crash preferred over silently skipping a
line.

### Credentials

Declare a sensitive `jellyfin_api_key` Terraform variable and pass it only to the
exporter. Its value belongs in the gitignored `.auto.tfvars`; it is never committed or
written into dashboard JSON. The operator creates the API key in Jellyfin before
applying this feature. Jellyfin does not scope these keys as read-only, so the exporter
and its environment must treat the credential as an administrative secret.

### Prometheus

Add `jellyfin-egress-exporter` to `observability/prometheus.yml` at the existing 15-second
scrape interval. No push gateway or recording-rule service is required.

## Dashboard Changes

Keep the existing aggregate panels and add:

1. **Public egress by user** — bar chart of
   `sum by (user) (increase(jellyfin_user_egress_bytes_total[$__range]))`.
2. **Upload rate by user** — time series of
   `sum by (user) (rate(jellyfin_user_egress_bytes_total[5m])) * 8`.
3. **User/IP attribution** — table grouped by `user` and `client_ip` over the selected
   range, including `unknown` rather than hiding it.

Grafana continues to use Prometheus as the dashboard datasource. The existing public
egress stat remains visible so the sum of per-user counters can be compared with the
Traefik aggregate.

## Failure Behaviour

- If Jellyfin's API is unavailable, the exporter continues using unexpired mappings.
  Once a mapping reaches its 10-minute TTL, new bytes use `unknown`.
- If the access log contains malformed or negative byte counts, the entry is skipped and
  an error counter increments.
- If the exporter is down, Traefik continues serving requests and writing logs. The
  exporter catches up from its checkpoint when it returns, subject to log retention.
- If log rotation removes data before it is consumed, the exporter records a checkpoint
  discontinuity and resumes at the start of the current file. It does not guess the
  missing byte count.
- A shared IP is intentionally attributed to the most recently observed user. There is
  no `shared` state and no attempt to apportion bytes among simultaneous sessions.

## Testing and Verification

Unit tests cover address normalization, latest-user-wins cache behaviour, mapping TTL,
router filtering, byte accumulation, malformed log lines, and checkpoint recovery.

Infrastructure verification consists of:

1. `terraform fmt -check` and `terraform validate` succeeding.
2. A Terraform plan containing only the expected Traefik, exporter, log-rotation,
   Prometheus configuration, and dashboard changes.
3. Prometheus reporting the exporter target as `UP`.
4. During a controlled external stream, the normalized `RemoteEndPoint` returned by
   Jellyfin matching the normalized `ClientHost` in Traefik's access log. This is a
   deployment gate: if they differ, configure trusted proxy handling before relying on
   attribution.
5. The controlled stream producing a labelled
   `jellyfin_user_egress_bytes_total` series for the active username and client IP.
6. The per-user increase closely reconciling with the increase in
   `traefik_router_responses_bytes_total{router="jellyfin@docker"}` over the same test
   window. Small differences are allowed for scrape boundaries and access-log rotation.
7. Restarting the exporter and confirming it resumes from its checkpoint without
   replaying the whole access log.
8. Confirming a Traefik access-log sample contains no authorization header, cookie,
   query parameters, or Jellyfin API token.

## Out of Scope

- Perfect attribution when users share an IP.
- LAN egress attribution.
- Wire-level accounting including TCP/IP or TLS overhead.
- Retroactive attribution of traffic recorded before this feature is deployed.
- Per-title, per-device, or per-session dashboard breakdowns.
