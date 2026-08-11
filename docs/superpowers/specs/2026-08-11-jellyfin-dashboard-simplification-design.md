# Jellyfin Dashboard Simplification Design

## Goal

Remove the redundant HTTP status-code cards and reorganize the Jellyfin dashboard into a clearer six-panel flow with more vertical room for both time-series graphs.

## Panel Inventory

Keep these existing panels and their IDs:

- `4`: p95 latency
- `9`: p99 latency
- `2`: Public egress
- `8`: Egress by user
- `1`: Public response accounting rate
- `3`: Request rate, public vs LAN

Remove these HTTP status-code panels entirely:

- `5`: 200
- `10`: 204
- `11`: 302
- `12`: 304
- `13`: 404
- `14`: 499
- `15`: 502
- `16`: Other

No replacement HTTP-code visualization is required.

## Layout

Use a 24-column grid with this exact non-overlapping layout:

| Panel | Grid position |
| --- | --- |
| p95 latency | `x=0, y=0, w=12, h=4` |
| p99 latency | `x=12, y=0, w=12, h=4` |
| Public egress | `x=0, y=4, w=6, h=6` |
| Egress by user | `x=6, y=4, w=18, h=6` |
| Public response accounting rate | `x=0, y=10, w=24, h=10` |
| Request rate, public vs LAN | `x=0, y=20, w=24, h=10` |

The reading order is latency health, total usage, usage attribution, bandwidth history, then request activity. The two graphs are full-width and ten grid rows high to prioritize time resolution and vertical detail over a one-screen layout.

## Preserved Behavior

- Preserve both Faro latency cards exactly, including three exclusive threshold zones, neutral pointer, visible value/quality spacing, raw numeric handling, thresholds, no-data reset, and 0–3 second scale.
- Preserve the exact PromQL, datasource, legend, field configuration, transformations, units, descriptions, and options of all six retained panels; change only their grid positions.
- Preserve `$__range` for summary/table/latency queries and `$__rate_interval` for both time-series queries.
- Preserve the dashboard's 24-hour default range, one-minute refresh, tags, title, UID, schema version, and read-only setting.
- Do not change exporter metrics, Grafana plugins, container configuration, authentication, or any Terraform resource outside `grafana_dashboard.jellyfin`.

## Verification

- Update executable dashboard tests to require exactly six unique panel IDs: `1`, `2`, `3`, `4`, `8`, and `9`.
- Assert that no removed status-code panel title, ID, or dedicated HTTP-code query remains.
- Assert the exact grid above and run exhaustive pairwise overlap checks.
- Retain all latency behavior, query, range-variable, Terraform interpolation, plugin pinning, and safety tests.
- Render the Terraform template as JSON and run the full observability suite, Terraform formatting, validation, and diff checks.
- Before deployment, require a saved Terraform plan whose only actionful resource is an in-place update to `grafana_dashboard.jellyfin`.
- After deployment, verify the six-panel layout and range refresh at 24 hours, 1 hour, and 5 minutes in the authenticated browser, require a clean console, and prove an empty isolated convergence plan.

## Safety

- Do not replace or restart Grafana or any other container.
- Do not run or apply a broad Terraform plan.
- Restore any temporary dependency-isolation edits before applying a saved plan and before interpreting convergence.
- Preserve all unrelated and user-owned working-tree changes.
