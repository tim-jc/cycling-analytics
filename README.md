# Cycling Analytics

Personal cycling analytics dashboard built with R Markdown, flexdashboard, and data from the cycling platform database.

## Getting Started

From a fresh clone, restore the project package library before rendering:

```sh
Rscript -e "install.packages('renv')"
Rscript -e "renv::restore()"
```

Configure the database and dashboard environment variables in a local `.Renviron` file or through your shell/CI environment. `.Renviron` is intentionally ignored by git.

CARTO raster maps also require the shared runtime variable:

```text
CARTO_BASEMAP_API_KEY=<your key>
```

Use the same variable name in `cycling-analytics` and `coastal`. For a container,
pass it at runtime through the production environment or Compose environment
configuration; do not add it to the Dockerfile or image.

Optional dashboard settings:

```sh
ANNUAL_DISTANCE_GOAL_MI=6000
```

If `ANNUAL_DISTANCE_GOAL_MI` is not set, the dashboard uses last year's total mileage as the annual distance goal.

Render the dashboard application with:

```sh
CYCLING_ANALYTICS_RUN_MODE=render Rscript render_dashboard.R
```

The render script resolves paths from the repository root, so it does not depend on a machine-specific working directory.
Its default and authoritative production mode validates configuration, reads
platform data, and renders a complete non-self-contained static site under
`output/`; it does not publish or notify. Set
`CYCLING_ANALYTICS_OUTPUT_DIR` to render to another directory.

The complete production runtime and output contract is documented in
[`docs/runtime-contract.md`](docs/runtime-contract.md).

The container may run under any operator-supplied UID/GID. Its entrypoint keeps
source and renv packages read-only, uses a per-UID temporary runtime tree for R
Markdown/cache files, and writes the persistent dashboard only to `/app/output`.

Production execution, scheduling, publication, notification and recovery are
owned by `cycling-infrastructure` on `cycling-prod`. Infrastructure currently
publishes the validated `output/` artefact to Cloudflare Pages. This repository
contains neither that deployment implementation nor Cloudflare credentials.
Git stores source and documentation; generated dashboard renders are ignored.
The Mac is a development environment rather than the scheduled production
runtime, and `docs/` contains documentation only.

## Tests

Run the focused regression suite from the repository root:

```sh
Rscript tests/run_tests.R
```

## Latest Ride dashboard page

The landing page shows the most recent cycling activity of at least 20 miles,
then loads telemetry and Gold power efforts only for that selected ride. Its
temporary selection policy and platform-product gaps are documented in
[`docs/latest-ride.md`](docs/latest-ride.md).

## Ride Summary PDF

Generate a compact post-ride coaching report with:

```sh
Rscript scripts/render_ride_summary.R --activity-id <activity-id>
```

An optional FTP input enables estimated training-load and power-zone sections.
See [`docs/ride-summary-report.md`](docs/ride-summary-report.md).

## Troubleshooting renv

If `render_dashboard.R` reports missing packages after `renv::restore()`, confirm that R is using the project library:

```sh
Rscript -e "source('renv/activate.R'); print(.libPaths()); print(requireNamespace('DBI', quietly = TRUE))"
```
