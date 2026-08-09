# Jellyfin egress dashboard redesign

Date: 2026-08-09
Status: Approved in conversation

## Goal

Make the Jellyfin dashboard compact and honest about what its metrics measure, while
reducing avoidable `unknown` attribution without risking lost or duplicated log records.

The redesign removes the two per-user graphs, replaces latency and status-code graphs
with compact stat cells, simplifies the attribution table to user totals, and makes every
panel honor the dashboard time picker.

## Verified root causes

### Known and unknown labels on the same client IP

Attribution is performed when each access-log record is processed. A response that is
processed before the next Jellyfin `/Sessions` poll has no username mapping and is
recorded as `unknown`. Later responses from the same IP use the newly observed username.
Prometheus retains both label histories, so seeing `unknown` and a username for one IP is
expected under immediate processing.

### Apparent upload rates above the ISP limit

Two independent effects were observed:

1. Exporter peaks of roughly 119 Mbit/s aligned exactly with exporter restarts and the
   one-time legacy-checkpoint migration. Historical response bytes were replayed into a
   fresh counter during one scrape interval, and `rate(...[5m])` interpreted that counter
   jump as traffic during the five-minute window.
2. Traefik's `traefik_router_responses_bytes_total` is response-byte accounting, not a
   physical WAN-interface meter. Large completed streaming responses produce counter
   jumps that a range rate spreads over its lookback. The public router can also include
   LAN or hairpin clients that use the public hostname.

The dashboard must not describe either series as authoritative ISP upload throughput.

## Attribution design

### Checkpoint-backed attribution delay

Extend each parsed public Jellyfin access event with Traefik's JSON logger `time` timestamp.
This is the access-record emission time and therefore follows response completion. Do not
use `StartUTC`: a long-running stream can have started hours before its response record is
written and would bypass the intended delay.
When the client IP has no current Jellyfin mapping:

1. If the event is less than 30 seconds old, stop processing before that record and leave
   the checkpoint unchanged.
2. Retry the same record on the tailer's next one-second pass.
3. If a mapping appears, assign the response bytes to the latest username for the IP and
   advance the checkpoint.
4. If the record reaches 30 seconds without a mapping, assign it to `unknown` and advance
   the checkpoint.

This uses the existing access log as the durable pending queue. No in-memory queue or
additional state file is required. A restart during the delay re-reads the same record.
Later records can be held behind an unresolved record for no more than 30 seconds.

The latest observed user wins for shared IPs. This can assign a delayed response to the
wrong user if an IP is rapidly reused, which is explicitly acceptable for this homelab.

### Timestamp handling

`time` must be a timezone-aware RFC 3339 timestamp. Missing, malformed, or timestamps more
than five seconds in the future are access-log parsing errors. They are counted and
checkpointed so a bad record cannot wedge the tailer. A timestamp up to five seconds in
the future is clamped to age zero.

If Jellyfin session polling is unavailable, records still become `unknown` after the
30-second deadline. API failure does not create an indefinite log backlog.

### Clean metric generation

Publish attributed bytes under:

```promql
jellyfin_user_egress_bytes_v2_total{user,client_ip}
```

The dashboard consumes only the v2 metric. The old
`jellyfin_user_egress_bytes_total` series remains in Prometheus until retention removes it
but is no longer queried. This creates a clean history boundary after the replay-contaminated
series without destructive Prometheus data deletion.

First start with no checkpoint continues to begin at the active log's EOF. Existing
anchored checkpoint validation and copy-truncate recovery remain unchanged.

## Dashboard design

### Top row

1. **Public response accounting rate** — time series using:

   ```promql
   sum(rate(traefik_router_responses_bytes_total{router="jellyfin@docker"}[$__rate_interval])) * 8
   ```

   Unit: `bps`. Description: completed response-byte accounting; not physical WAN-interface
   throughput and may include public-hostname hairpin traffic.

2. **Public egress** — stat scoped to the selected range:

   ```promql
   sum(increase(traefik_router_responses_bytes_total{router="jellyfin@docker"}[$__range]))
   ```

   Unit: `decbytes`.

### Middle row

1. **Egress by user** — table using:

   ```promql
   sort_desc(sum by (user) (increase(jellyfin_user_egress_bytes_v2_total[$__range])))
   ```

   The only visible columns are `User` and `Egress`. `Egress` uses `decbytes`, and the
   table's panel sort is descending by `Egress`. `unknown` is not filtered.

2. **Request latency** — one stat visualization containing separate p95 and p99 cells:

   ```promql
   histogram_quantile(0.95, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router="jellyfin@docker"}[$__range])))
   ```

   ```promql
   histogram_quantile(0.99, sum by (le) (increase(traefik_router_request_duration_seconds_bucket{router="jellyfin@docker"}[$__range])))
   ```

   Unit: seconds. Both queries are instant queries over the selected range.

3. **Status codes** — one stat visualization that renders a compact cell per returned code:

   ```promql
   sum by (code) (increase(traefik_router_requests_total{router="jellyfin@docker"}[$__range]))
   ```

   Unit: short request count. The code label is the displayed cell name.

### Bottom row

**Request rate, public vs LAN** remains a time series, but its fixed five-minute lookback
is replaced with Grafana's adaptive interval:

```promql
sum by (router) (rate(traefik_router_requests_total{router=~"jellyfin(local)?@docker"}[$__rate_interval]))
```

### Removed panels

- Public egress by user
- Upload rate by user

Every instant summary uses `$__range`; every remaining time series is bounded by the
dashboard x-axis and uses `$__rate_interval` rather than a fixed lookback.

## Deployment scope

Expected live changes are limited to:

- replacement of `jellyfin-egress-exporter` for the uploaded script change;
- an in-place update of `grafana_dashboard.jellyfin`.

Traefik, Jellyfin, Prometheus, and Grafana containers must not be replaced. Known unrelated
container-image digest drift must be excluded with reviewed targeted plans, as in the
initial feature deployment.

## Verification

### Exporter tests

Add test-first coverage for:

- an unmapped record younger than 30 seconds remains unprocessed and uncheckpointed;
- the same record is attributed after a mapping arrives;
- an unmapped record becomes `unknown` at the 30-second deadline;
- restart/re-entry reads the delayed record exactly once;
- a delayed record blocks following records only until its deadline;
- malformed, missing, and more-than-five-seconds-future `time` values are counted and checkpointed;
- timezone offsets normalize correctly;
- the v2 metric name is emitted and the old name is absent from new output;
- anchored checkpoint and copy-truncate regression behavior remains intact.

### Dashboard checks

Validate that the rendered template:

- is valid JSON;
- contains six panels after removing panels 6 and 7;
- contains no query for the old attribution metric;
- contains the v2 table query grouped only by `user`;
- hides `client_ip` by removing it from the query and visible fields;
- sorts the table by `Egress` descending;
- uses stat visualizations for status codes and p95/p99 latency;
- uses `$__range` for instant summaries and `$__rate_interval` for time series;
- retains `unknown` without filtering.

Run the full Python suite, compilation checks, `terraform fmt -check`, and
`terraform validate`. Review saved targeted plans before applying.

### Live gates

After deployment:

- Prometheus reports the exporter target `UP` with no scrape error;
- a new external playback response waits briefly for mapping and appears under the active
  username in the v2 series;
- a deliberately unmapped or naturally unmapped response eventually appears as `unknown`;
- checkpoint offsets advance without replay or discontinuity;
- the authenticated Grafana dashboard visibly contains the six intended panels, the user
  table has two columns sorted descending, and all stat cells respond to time-range changes;
- no service other than the exporter is restarted.
