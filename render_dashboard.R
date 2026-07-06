# build cycling-analytics dashboard

# clear environment -------------------------------------------------------

rm(list = ls(all = TRUE))

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

# Render and publish ------------------------------------------------------

# Render dashboard
rmarkdown::render(
  here::here("dashboards/index.Rmd"),
  output_file = "index.html",
  output_dir = here::here("docs/")
)

# Push updated dashboard to git
publish_to_git()

# Send notification
send_ntfy_message(ntfy_msg)

# Final messages for log

log_message("Disconnecting database connection...")

DBI::dbDisconnect(con)

log_message("Scraper complete.")
