# Jellyfin Faro-Style Latency Cards Design

## Goal

Replace the oversized p95 and p99 Bar Gauge panels with compact latency cards that reproduce the useful parts of Grafana Cloud Frontend Observability's Faro presentation: the measured value and unit above a thin horizontal meter, a current-value pointer, labelled threshold indicators, and an explicit quality label.

## Problem

The current panels use Grafana's native `bargauge` visualization with automatic sizing. Each panel contains only one value, so Grafana expands that one horizontal bar to almost the full panel height. Although its fill progresses from left to right, the tall filled edge appears vertical and the value is pushed to the far right. This does not resemble the Faro card the dashboard was intended to follow.

Changing Bar Gauge sizing can make the bar thinner, but the native panel cannot place a large value above the meter or add Faro's moving triangular pointer and labelled threshold ticks. The existing latency PromQL, returned values, units, and selected-range behavior are correct; this is a rendering problem.

## Chosen Approach

Use the signed Business Text panel plugin, ID `marcusolsson-dynamictext-panel`, for the two latency cards. The plugin is listed in Grafana's official plugin catalog and is maintained by Grafana Labs. It accepts query results and renders a sanitized Handlebars/HTML template with panel-local CSS, which is sufficient to build the Faro-style card without enabling Grafana's global unsafe-HTML setting.

Install the plugin declaratively on the Grafana container with:

```text
GF_PLUGINS_PREINSTALL=marcusolsson-dynamictext-panel@<verified-version>
```

The implementation must pin an exact plugin version. The repository currently uses `grafana/grafana:latest`, and the running instance reports Grafana 13.1.3. Published Business Text 6.x requirements currently name Grafana 11 and 12 rather than 13, so compatibility is a hard preflight gate: verify a signed catalog release loads and renders on the running Grafana version before changing or replacing the managed Grafana container. If no compatible signed release is available, stop and report the blocker; do not downgrade Grafana, enable unsigned plugins, or enable `GF_PANELS_DISABLE_SANITIZE_HTML`.

## Card Appearance

Keep two independent cards titled `p95 latency` and `p99 latency`. Each card contains, from top to bottom:

1. A value line such as `131 ms (Good)`. The numeric value and `ms` unit appear together above the meter. The quality label follows in parentheses.
2. A thin horizontal meter whose fill ends at the current value.
3. A small downward-pointing triangular pointer aligned to the current value.
4. Two labelled threshold ticks below the meter: `1 s` and `2 s`.

The meter uses the existing fixed 0–5 second scale. Pointer position is clamped to the visual range so values below zero render at the left edge and values above five seconds render at the right edge while the displayed value remains accurate.

Quality and colour use the existing absolute thresholds:

| Latency | Label | Colour |
|---|---|---|
| less than 1 second | Good | green |
| at least 1 second and less than 2 seconds | Needs improvement | amber |
| at least 2 seconds | Poor | red |

The value, label, meter fill, and pointer use the current quality colour. The unfilled meter remains neutral grey. Threshold ticks remain visible regardless of the current value. `No data` is rendered explicitly when the query has no numeric sample; it must not be presented as zero or `Good`.

Panel-local CSS must use Grafana theme variables where practical, avoid external assets, and keep both cards legible at the existing six-column width. The cards should be shorter than the current eight-row Bar Gauges, with surrounding panels reflowed without overlap.

## Data and Time Range

Keep the current p95 and p99 Prometheus queries unchanged. They continue to use `histogram_quantile` over `$__range`, remain instant queries, and therefore recalculate from the selected dashboard time range.

The Business Text rendering reads the reduced numeric result from its own query response. It does not issue network requests, access credentials, or modify data. Presentation logic converts seconds to a readable latency value, using milliseconds for sub-second results and seconds for larger results.

No other dashboard query or time-range variable changes. Public egress, egress by user, status cards, and both time-series graphs retain their existing behavior.

## Files and Infrastructure Impact

Expected tracked changes are limited to:

- `observability.tf`: add the pinned Business Text plugin to the Grafana container environment;
- `observability/jellyfin-dashboard.json.tftpl`: replace the two `bargauge` definitions with Business Text panels and reflow the affected grid rows.

Installing the plugin changes the Grafana container configuration and requires Terraform to replace that container. The persistent `/var/lib/grafana` mount remains unchanged, so dashboards and Grafana state survive the replacement. The deployment can briefly interrupt dashboard access and monitoring visualization; it does not restart Prometheus, Traefik, Jellyfin, or the egress exporter.

## Security and Maintenance

- Use only a signed plugin release from Grafana's official catalog.
- Pin the plugin version rather than following `latest`.
- Keep Grafana's HTML sanitization enabled.
- Do not load JavaScript, fonts, styles, or images from third-party URLs.
- Keep all template logic and CSS inside the Terraform-managed dashboard JSON.
- Do not make dashboard edits in the Grafana UI because Terraform would overwrite them.

## Validation and Deployment Gates

Before any live change:

1. Confirm the chosen plugin archive is signed and compatible with Grafana 13.1.3 in an isolated disposable Grafana instance.
2. Render the dashboard template with a test datasource UID and validate the JSON.
3. Assert there are still fourteen unique, non-overlapping panels.
4. Assert p95 and p99 use `marcusolsson-dynamictext-panel`, preserve their exact PromQL and `$__range`, and contain the value, meter, pointer, 1-second tick, 2-second tick, and all three quality states.
5. Assert neither latency panel remains a `bargauge`.
6. Run repository formatting, Terraform validation, and dashboard structural checks.
7. Generate narrowly targeted Terraform plans. Review all actionful resources before applying; never apply unrelated mutable-image drift.

Deployment order is Grafana/plugin first, then the dashboard if those changes cannot be safely applied in one reviewed plan. After deployment, verify:

- Grafana is healthy and the plugin is loaded and signed;
- both cards render their live value and unit above a thin horizontal meter;
- the pointer and the 1-second/2-second indicators are visible and correctly aligned;
- the quality label and colour match the measured value;
- changing the dashboard range recalculates both cards;
- all other panels still render;
- a convergence plan has no remaining actionful changes.

## Rollback

Rollback restores the previous dashboard JSON and removes the plugin preinstall environment entry, then applies only the reviewed Grafana/dashboard changes. Persistent Grafana data is retained throughout.

## Out of Scope

- Changing latency aggregation semantics or thresholds.
- Changing egress attribution or traffic accounting.
- Reproducing Grafana Cloud navigation, tooltips, or other proprietary Frontend Observability application chrome.
- Downgrading or pinning Grafana itself as part of this change.
