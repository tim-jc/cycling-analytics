# Cycling Analytics

Personal cycling analytics dashboard built with R Markdown, flexdashboard, and data from the cycling platform database.

## Getting Started

From a fresh clone, restore the project package library before rendering:

```sh
Rscript -e "install.packages('renv')"
Rscript -e "renv::restore()"
```

Configure the database and dashboard environment variables in a local `.Renviron` file or through your shell/CI environment. `.Renviron` is intentionally ignored by git.

Optional dashboard settings:

```sh
ANNUAL_DISTANCE_GOAL_MI=6000
```

If `ANNUAL_DISTANCE_GOAL_MI` is not set, the dashboard uses last year's total mileage as the annual distance goal.

Render the dashboard with:

```sh
Rscript render_dashboard.R
```

The render script resolves paths from the repository root, so it does not depend on a machine-specific working directory.

## Scheduled Refreshes

Set `DASHBOARD_REFRESH_SCHEDULE` to a standard five-field cron expression, then install the managed cron block from an R session:

```r
source("runtime_helpers.R")
install_cron_job()
```

The cron entry runs `scripts/run_dashboard_refresh.sh`, which changes to the project root and feeds `render_dashboard.R` to `Rscript` through stdin. Output is written to `dashboard_refresh.log`. The render script does not require or use a `cron` command-line argument.

The refresh log records the wrapper environment, R library paths, major render stages, git commands, elapsed times, and failure context. Start there when diagnosing unattended refresh failures.

Re-run `install_cron_job()` after changing the repository path, R installation, or cron helper so the managed crontab block is regenerated.

## Troubleshooting renv

If `render_dashboard.R` reports missing packages after `renv::restore()`, confirm that R is using the project library:

```sh
Rscript -e "source('renv/activate.R'); print(.libPaths()); print(requireNamespace('DBI', quietly = TRUE))"
```
