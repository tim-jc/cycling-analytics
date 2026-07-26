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
| `CYCLING_ANALYTICS_OUTPUT_DIR` | `docs` | Absolute path or path relative to the repository root |
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

The application creates:

```text
${CYCLING_ANALYTICS_OUTPUT_DIR:-docs}/index.html
```

The output directory is created when necessary. Rendering does not require the
directory to be inside a Git repository.

Publication is deliberately outside the production application contract. The
future deployment may either:

1. render into a writable Git checkout and publish through GitHub Pages; or
2. render into a mounted/persistent directory and let infrastructure serve or
   publish it.

That choice is deferred to container/infrastructure design.

## Logging

Application logs are written to stderr/stdout and retain these stages:

- Initialise
- Validate configuration
- Connect database
- Load data
- Render dashboard
- Complete
- Cleanup

If `DASHBOARD_LOG` is configured outside redirected execution, application logs
are also appended to that file. Container infrastructure may collect standard
output without changing application logging.

Errors include the active stage and runtime context and propagate as a non-zero
process exit status.

## Database and network dependency

The application requires network access to the production MariaDB instance and
a read-only user able to select:

- `cycling_platform_silver.activities`
- `cycling_platform_silver.activity_streams`
- `cycling_platform_gold.activity_best_efforts`

The current dashboard also uses reverse geocoding while preparing map summary
content. Rendered maps load Carto/OpenStreetMap tiles in the browser.

## Local publication convenience

The existing Git publication and ntfy path remains available explicitly for
local development:

```sh
CYCLING_ANALYTICS_RUN_MODE=local_publish Rscript render_dashboard.R
```

This is not the authoritative production execution contract.

## Scheduling and locking

Scheduling, concurrency control and production locking are infrastructure
responsibilities.

The existing macOS cron wrapper remains supported until migration. Its
directory lock now records an owner PID and recovers a stale lock. That mechanism
does not prescribe the future Linux/container locking design.
