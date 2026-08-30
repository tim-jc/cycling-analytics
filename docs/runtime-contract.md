# Cycling Analytics Runtime Contract

## Application responsibility

`cycling-analytics` is a batch application. Its authoritative production
responsibility is:

```text
validate configuration
  -> connect to trusted cycling-platform data
  -> load and prepare presentation data
  -> render a static dashboard artefact
  -> return success or failure
```

It does not require cron, Docker, a mutable Git checkout, Git credentials or a
notification service in order to render.

## Production application command

```sh
CYCLING_ANALYTICS_RUN_MODE=render Rscript render_dashboard.R
```

`render` is the default run mode, so the prefix may be omitted. The explicit
form is recommended for production orchestration.

The command exits with status `0` after a successful render and non-zero after
configuration, database, data-loading or rendering failure.

## Required configuration

| Variable | Requirement |
|---|---|
| `MARIADB_HOST` | Required database hostname |
| `MARIADB_PORT` | Required integer from 1 to 65535 |
| `MARIADB_NAME` | Required database name |
| `MARIADB_USER` | Required read-only database user |
| `MARIADB_PASSWORD` | Required database password/secret |

Production supplies these values through the process environment. Local
development may continue to use the ignored `.Renviron` file.
The local `.Renviron` must not be copied or mounted into a production runtime:
R/renv can load it and override injected process values.

## Optional application configuration

| Variable | Default | Purpose |
|---|---|---|
| `CYCLING_ANALYTICS_TIMEZONE` | `Europe/London` | User/calendar timezone used by R |
| `CYCLING_ANALYTICS_OUTPUT_DIR` | `output` | Root of the complete static-site artefact; absolute or relative to the repository root |
| `CYCLING_ANALYTICS_RENDER_DIR` | R session temporary directory | R Markdown intermediate files |
| `ANNUAL_DISTANCE_GOAL_MI` | Previous-year total | Positive annual mileage goal |
| `RSTUDIO_PANDOC` | Auto-discovered | Explicit local Pandoc location when needed |

The database queries use explicit date boundaries calculated in the application
timezone rather than MariaDB `NOW()` for the dashboard's calendar windows.
Production should configure MariaDB consistently, but dashboard period
selection does not depend on the database server's current date.

The application does not require a particular regional locale. Runtime
orchestration should provide a valid UTF-8 locale for its host. The exact Linux
locale will be chosen during container design.

## Output contract

The application artefact is a complete, publication-neutral static-site
directory:

```text
${CYCLING_ANALYTICS_OUTPUT_DIR:-output}/
├── index.html
└── index_files/
    └── ...
```

`index.html` is deliberately non-self-contained. Every local CSS, JavaScript,
font and htmlwidget dependency it references under `index_files/` must exist
beneath the same output root. The output directory is generated content and is
ignored by Git; genuine project documentation remains under `docs/`.

Rendering uses three distinct locations:

1. dashboard source remains read-only under `dashboards/`;
2. R Markdown/Pandoc intermediate files use `CYCLING_ANALYTICS_RENDER_DIR`;
3. the complete new site is rendered into a hidden staging directory on the
   output filesystem.

The staged site is validated before finalisation. Finalisation backs up the
current site, promotes all dependencies, promotes `index.html` last, validates
the durable result, and rolls back if any promotion step fails. A failed render
or validation therefore leaves the previous successful site intact.

Publication is deliberately outside the application contract. A separate
publication mechanism may consume the complete output directory, but no
hosting provider is selected or implemented here.

## Container filesystem contract

The container supports an arbitrary externally supplied numeric UID/GID. Its
source at `/opt/cycling-analytics` and renv library at
`/opt/cycling-analytics-library` remain read-only at runtime.

The container entrypoint creates a per-UID ephemeral runtime tree at
`/tmp/cycling-analytics-<uid>` and configures:

| Location | Purpose |
|---|---|
| `home/` | Writable `HOME` and `R_USER` |
| `cache/` | `XDG_CACHE_HOME`, including the R/sass cache |
| `tmp/` | `TMPDIR` and R temporary files |
| `render/` | R Markdown and Pandoc intermediate files |

`CYCLING_ANALYTICS_RUNTIME_DIR` may replace the runtime-tree root when needed.
The entrypoint creates and verifies these directories after the external
runtime identity has been applied; no production UID or GID is baked into the
image.

Every image build runs `tests/smoke_check.R` after application assembly. This
offline check verifies the production files, restored R library and packages,
Pandoc discovery, and production render-code syntax. It does not connect to
MariaDB, contact CARTO, render the dashboard, or prove non-root runtime access.

Production mounts its writable persistent output at `/app/output`. The image
also supplies a writable `/app/output` mount point so an ordinary unmounted
`docker run` works. No rendering step requires write access to the application
source tree.

## Logging

Application logs are written to stderr/stdout and retain these stages:

- Initialise
- Validate configuration
- Connect database
- Load data
- Render dashboard
- Validate dashboard artefact
- Finalise dashboard artefact
- Complete
- Cleanup

If `DASHBOARD_LOG` is explicitly configured outside redirected execution,
application logs are also appended to that file. With no explicit file, logs
go only to stderr/stdout; the application never defaults to writing a log in
its source tree. Container infrastructure may collect standard output without
changing application logging.

Errors include the active stage and runtime context and propagate as a non-zero
process exit status.

## Database and network dependency

The application requires network access to the production MariaDB instance and
a read-only user able to select:

- `cycling_platform_silver.activities`
- `cycling_platform_silver.activity_streams`
- `cycling_platform_gold.activity_best_efforts`

The current dashboard also uses reverse geocoding while preparing map summary
content. Rendered maps load CARTO/OpenStreetMap tiles in the browser. CARTO
raster maps require `CARTO_BASEMAP_API_KEY`; supply it to the container at
runtime through the production environment or future Compose configuration.
It must not be embedded in the Dockerfile or image.

## Historical local publication convenience

The existing Git publication and ntfy path remains available explicitly for
local development:

```sh
CYCLING_ANALYTICS_RUN_MODE=local_publish Rscript render_dashboard.R
```

This is not the authoritative production execution contract. The retained
Git-based local publication helper still reflects the historical GitHub Pages
workflow; the publication-neutral production artefact is always the complete
configured output directory and must not be reduced to a single copied HTML
file.

## Scheduling and locking

Scheduling, concurrency control and production locking are infrastructure
responsibilities. On the Pi, infrastructure passes
`CYCLING_ANALYTICS_NEXT_REFRESH_TEXT` only as notification display context; the
application displays the supplied value without deriving or parsing the Pi
production schedule. In production `render` mode, a missing or empty value is
reported as `not scheduled`. `local_publish` retains its existing
`DASHBOARD_REFRESH_SCHEDULE` calculation for local-development notifications.

The retained `local_publish` path may still calculate a local next run from
`DASHBOARD_REFRESH_SCHEDULE`; it is not authoritative for Pi production
scheduling.
