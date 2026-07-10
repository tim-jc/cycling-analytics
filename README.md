# Cycling Analytics

Personal cycling analytics dashboard built with R Markdown, flexdashboard, and data from the cycling platform database.

## Getting Started

From a fresh clone, restore the project package library before rendering:

```sh
Rscript -e "install.packages('renv')"
Rscript -e "renv::restore()"
```

Configure the database and dashboard environment variables in a local `.Renviron` file or through your shell/CI environment. `.Renviron` is intentionally ignored by git.

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

The cron entry runs `render_dashboard.R` directly and writes output to `dashboard_refresh.log`. The render script does not require or use a `cron` command-line argument.

Re-run `install_cron_job()` after changing the repository path, R installation, or cron helper so the managed crontab block is regenerated.

## Troubleshooting renv

If `render_dashboard.R` reports missing packages after `renv::restore()`, confirm that R is using the project library:

```sh
Rscript -e "source('renv/activate.R'); print(.libPaths()); print(requireNamespace('DBI', quietly = TRUE))"
```
