# Ride Summary report

The Ride Summary is a compact Quarto PDF for post-ride coaching discussion. It
accepts one activity ID and produces a static report without publishing or
modifying platform data.

## Command

```sh
Rscript scripts/render_ride_summary.R \
  --activity-id 19457478741 \
  --ftp-watts 250 \
  --session-objective "Long steady endurance ride; pacing practice"
```

Output defaults to `output/pdf/ride-summary-<activity-id>.pdf`. Use
`--output-dir <path>` to choose another destination. Only `--activity-id` is
required; FTP-dependent metrics degrade gracefully.

## Architecture

```text
activity ID
  -> read-only report data adapters
  -> pure report/presentation model
  -> reusable tables and plots
  -> Quarto/Typst PDF
```

The data, model and presentation components are separate so a future MCP
adapter can reuse the report model without parsing a rendered PDF.

Trusted inputs are `silver.activities`, `silver.activity_streams`, and
`gold.activity_best_efforts`.

## Temporary report-only logic

The following calculations are isolated in `ride_report_model.R` and visibly
labelled as estimates:

- FTP-based power-zone allocation
- positive stream-altitude gain and VAM for selected effort windows
- rejection of Gold effort windows containing elapsed-time discontinuities
- 30-second context before and after selected effort plots

Effort rejection is a presentation safeguard, not a replacement best-effort
calculation. If Gold's leading window is discontinuous, that duration remains
absent until the platform supplies the next valid continuous window.

NP, VI, IF and TSS are omitted until canonical products exist. Laps are also
omitted until cycling-platform publishes a curated lap product.

## Missing platform products

Future versions would benefit from:

- curated activity laps with stable summary fields
- activity and lap NP/IF/TSS plus FTP history
- canonical power-zone time
- detected climbs and structured intervals
- effort elevation gain and VAM
- HR-power decoupling
- weather associated with an activity
- equipment display identity from bike-library through an agreed interface
