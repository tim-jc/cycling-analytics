# build cycling-analytics dashboard

main <- function() {
  # project setup -----------------------------------------------------------

  setwd(normalizePath("~/Documents/Coding/R/Strava/cycling-analytics"))

  here::i_am("render_dashboard.R")

  # source runtime helpers --------------------------------------------------

  source(here::here("db/db.R"))
  source(here::here("runtime_helpers.R"))
  source(here::here("dashboard_functions.R"))

  # environment -------------------------------------------------------------

  # load environment variables
  readRenviron(here::here(".Renviron"))

  # set pandoc environment
  Sys.setenv(
    RSTUDIO_PANDOC = Sys.getenv("RSTUDIO_PANDOC")
  )

  render_env <- new.env(parent = environment())

  on.exit(
    {
      if (exists("con", envir = render_env, inherits = FALSE) &&
          DBI::dbIsValid(render_env$con)) {
        log_message("Disconnecting database connection...")
        DBI::dbDisconnect(render_env$con)
      }
    },
    add = TRUE
  )

  # Render and publish ------------------------------------------------------

  # Render dashboard
  rmarkdown::render(
    here::here("dashboards/index.Rmd"),
    output_file = "index.html",
    output_dir = here::here("docs/"),
    envir = render_env
  )

  # Push updated dashboard to git
  publish_to_git()

  # Send notification
  ntfy_msg <- glue::glue(
    "Cycling Analytics dashboard refreshed at {format(Sys.time(), '%Y-%m-%d %H:%M:%S')}."
  )

  send_ntfy_message(ntfy_msg)

  log_message("Scraper complete.")
}

main()
