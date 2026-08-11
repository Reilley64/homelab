# Jellyfin Faro Latency Meter Refinement

## Goal

Make the Jellyfin p95 and p99 latency cards visually match the supplied Grafana Faro reference while preserving their existing range-scoped Prometheus queries, latency thresholds, and data handling.

## Layout

- Place p95 latency and p99 latency in the dashboard's first row.
- Give each card half the dashboard width: p95 at `x=0, w=12` and p99 at `x=12, w=12`.
- Make both cards four grid rows high at `y=0, h=4`.
- Move the existing dashboard rows down by four grid rows without changing their relative layout, panel sizes, queries, or behavior.
- Preserve a compact, non-overlapping 24-column dashboard grid.

## Latency Card Presentation

Each card keeps its native Grafana panel title. Inside the card:

- Show the latency value, unit, and quality label together above the meter and left-aligned.
- Keep the current quality thresholds: Good below 1 second, Needs improvement from 1 second up to but not including 2 seconds, and Poor at 2 seconds or above.
- Keep the value and quality text colored green, amber, or red according to that status.
- Render the meter as a threshold guide rather than a progress fill:
  - the first third is a fixed green Good zone representing 0–1 second;
  - the remaining two thirds use the neutral Grafana track color;
  - a neutral light downward triangle marks the current value independently of the Good zone;
  - threshold ticks and labels appear at one third (`1 s`) and two thirds (`2 s`).
- Map the pointer linearly across a 0–3 second visual scale and clamp values at or above 3 seconds to the right edge.
- Retain threshold-safe display formatting so shown values do not visually cross a status boundary because of rounding.
- When no finite sample exists, show neutral `No data`, clear the quality label and status state, reset the pointer to the left edge, and retain the fixed threshold guide.

## Data and Scope

- Preserve the p95 and p99 PromQL expressions exactly.
- Preserve `instant: true` and `$__range` dashboard-range behavior.
- Continue using the pinned Business Text plugin already installed for Grafana.
- Do not change exporter metrics, attribution logic, other panel queries, status cards, table contents, or Grafana authentication.

## Verification

- Add executable regression coverage for panel geometry, row reflow, non-overlap, fixed Good-zone geometry, neutral independent pointer, one-third/two-thirds threshold positions, and 0–3 second clamping.
- Preserve existing raw-number, stale-state reset, threshold-boundary, query, template-rendering, and dashboard-range tests.
- Render the Terraform template as JSON and validate its structure.
- Run the full observability test suite, Terraform formatting, Terraform validation, and diff checks.
- Before deployment, require a saved Terraform plan whose only actionful resource is an in-place update to `grafana_dashboard.jellyfin`.
- After deployment, verify the three required dashboard ranges, browser console, deployed dashboard definition, and an empty isolated convergence plan. If live latency samples are unavailable, verify the truthful neutral state without fabricating data.

## Safety

- Do not replace or restart Grafana or any other container for this refinement.
- Do not apply a broad Terraform plan.
- Preserve all unrelated and user-owned working-tree changes.
