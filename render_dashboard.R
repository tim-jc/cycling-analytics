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

check_required_packages <- function(packages, project_root) {
  missing_packages <- packages[
    !vapply(packages, requireNamespace, logical(1), quietly = TRUE)
  ]

  if (length(missing_packages) == 0) {
    return(invisible(TRUE))
  }

  stop(
    "Missing required package(s) in the active R library: ",
    paste(missing_packages, collapse = ", "),
    "\nDetected project root: ",
    project_root,
    "\nActive library paths:\n- ",
    paste(.libPaths(), collapse = "\n- "),
    "\nRun `Rscript -e \"renv::restore()\"` from the project root, then retry `Rscript render_dashboard.R`.",
    call. = FALSE
  )
}

main <- function() {
  # project setup -----------------------------------------------------------

  project_root <- get_project_root()

  old_wd <- setwd(project_root)
  on.exit(setwd(old_wd), add = TRUE)

  Sys.setenv(RENV_PROJECT = project_root)

  renv_activate <- file.path(project_root, "renv", "activate.R")
  if (file.exists(renv_activate)) {
    source(renv_activate)
  }

  check_required_packages(
    c(
      "DBI",
      "RMariaDB",
      "flexdashboard",
      "tidyverse",
      "plotly",
      "leaflet",
      "leaflet.extras",
      "lubridate",
      "mapdata",
      "rmarkdown",
      "tibble",
      "tidygeocoder",
      "glue",
      "htmlwidgets",
      "httr",
      "withr"
    ),
    project_root
  )

  # source runtime helpers --------------------------------------------------

  source(file.path(project_root, "db", "db.R"))
  source(file.path(project_root, "runtime_helpers.R"))
  source(file.path(project_root, "dashboard_functions.R"))

  # environment -------------------------------------------------------------

  # load local environment variables when present
  environ_path <- file.path(project_root, ".Renviron")
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
    file.path(project_root, "dashboards", "index.Rmd"),
    output_file = "index.html",
    output_dir = file.path(project_root, "docs"),
    envir = render_env
  )

  # Push updated dashboard to git
  publish_to_git(git_path = project_root)

  # Send notification
  ntfy_msg <- glue::glue(
    "Cycling Analytics dashboard refreshed at {format(Sys.time(), '%Y-%m-%d %H:%M:%S')}."
  )

  send_ntfy_message(ntfy_msg)

  log_message("Dashboard refresh complete.")
}

main()
