# build cycling-analytics dashboard

get_project_root <- function() {
  file_arg <- grep(
    "^--file=",
    commandArgs(trailingOnly = FALSE),
    value = TRUE
  )

  if (length(file_arg) > 0) {
    script_path <- sub("^--file=", "", file_arg[[1]])

    return(dirname(normalizePath(
      script_path,
      winslash = "/",
      mustWork = TRUE
    )))
  }

  normalizePath(
    getwd(),
    winslash = "/",
    mustWork = TRUE
  )
}

main <- function() {
  # project setup -----------------------------------------------------------

  project_root <- get_project_root()

  renv_activate <- file.path(project_root, "renv", "activate.R")
  if (file.exists(renv_activate)) {
    source(renv_activate)
  }

  old_wd <- setwd(project_root)
  on.exit(setwd(old_wd), add = TRUE)

  here::i_am("render_dashboard.R")

  # source runtime helpers --------------------------------------------------

  source(here::here("db/db.R"))
  source(here::here("runtime_helpers.R"))
  source(here::here("dashboard_functions.R"))

  # environment -------------------------------------------------------------

  # load local environment variables when present
  environ_path <- here::here(".Renviron")
  if (file.exists(environ_path)) {
    readRenviron(environ_path)
  }

  # Honour an explicit Pandoc path when configured; otherwise let rmarkdown
  # discover Pandoc from the current R installation or PATH.
  rstudio_pandoc <- Sys.getenv("RSTUDIO_PANDOC")
  if (nzchar(rstudio_pandoc)) {
    Sys.setenv(RSTUDIO_PANDOC = rstudio_pandoc)
  }

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

  log_message("Dashboard refresh complete.")
}

main()
