# build cycling-analytics dashboard

dashboard_timestamp <- function() {
  format(Sys.time(), "%Y-%m-%d %H:%M:%S")
}

dashboard_log_path <- function() {
  configured_log <- Sys.getenv("DASHBOARD_LOG", "")

  if (nzchar(configured_log)) {
    return(configured_log)
  }

  NA_character_
}

dashboard_log <- function(msg) {
  log_lines <- sprintf("[%s] %s", dashboard_timestamp(), msg)

  message(log_lines)

  if (identical(Sys.getenv("DASHBOARD_LOG_REDIRECTED", ""), "TRUE")) {
    flush.console()
    return(invisible(TRUE))
  }

  log_file <- tryCatch(
    dashboard_log_path(),
    error = function(e) NA_character_
  )

  if (!is.na(log_file) && nzchar(log_file)) {
    tryCatch(
      suppressWarnings(
        cat(
          paste(log_lines, collapse = "\n"),
          "\n",
          file = log_file,
          append = TRUE
        )
      ),
      error = function(e) {
        message(sprintf(
          "[%s] Log file append skipped: %s",
          dashboard_timestamp(),
          conditionMessage(e)
        ))
      }
    )
  }

  flush.console()
}

dashboard_runtime_context <- function() {
  paste(
    sprintf("cwd=%s", getwd()),
    sprintf("PATH=%s", Sys.getenv("PATH", "")),
    sprintf("HOME=%s", Sys.getenv("HOME", "")),
    sprintf("TMPDIR=%s", Sys.getenv("TMPDIR", "")),
    sprintf("XDG_CACHE_HOME=%s", Sys.getenv("XDG_CACHE_HOME", "")),
    sprintf(
      "CYCLING_ANALYTICS_RENDER_DIR=%s",
      Sys.getenv("CYCLING_ANALYTICS_RENDER_DIR", "")
    ),
    sprintf(
      "CYCLING_ANALYTICS_OUTPUT_DIR=%s",
      Sys.getenv("CYCLING_ANALYTICS_OUTPUT_DIR", "")
    ),
    sprintf("SHELL=%s", Sys.getenv("SHELL", "")),
    sprintf(".libPaths()=%s", paste(.libPaths(), collapse = " | ")),
    sep = "\n"
  )
}

run_dashboard_stage <- function(stage_name, expr) {
  started_at <- Sys.time()
  previous_stage <- getOption("cycling_analytics_stage", NULL)
  options(cycling_analytics_stage = stage_name)
  on.exit(
    options(cycling_analytics_stage = previous_stage),
    add = TRUE
  )

  dashboard_log(sprintf(
    "Stage=%s status=started cwd=%s",
    stage_name,
    getwd()
  ))

  tryCatch(
    {
      result <- force(expr)
      dashboard_log(sprintf(
        "Stage=%s status=success elapsed_seconds=%.1f cwd=%s",
        stage_name,
        as.numeric(difftime(Sys.time(), started_at, units = "secs")),
        getwd()
      ))
      result
    },
    error = function(e) {
      if (is.null(getOption("cycling_analytics_failed_stage", NULL))) {
        options(cycling_analytics_failed_stage = stage_name)
      }
      dashboard_log(sprintf(
        "Stage=%s status=failed elapsed_seconds=%.1f cwd=%s",
        stage_name,
        as.numeric(difftime(Sys.time(), started_at, units = "secs")),
        getwd()
      ))
      dashboard_log(sprintf(
        "Stage=%s error=%s",
        stage_name,
        conditionMessage(e)
      ))
      dashboard_log("Failure context:")
      dashboard_log(dashboard_runtime_context())
      stop(e)
    }
  )
}

get_project_root <- function() {
  configured_project <- Sys.getenv("CYCLING_ANALYTICS_PROJECT_DIR", "")

  if (!nzchar(configured_project)) {
    configured_project <- Sys.getenv("RENV_PROJECT", "")
  }

  if (nzchar(configured_project)) {
    return(normalizePath(
      configured_project,
      winslash = "/",
      mustWork = TRUE
    ))
  }

  file_arg <- grep(
    "^--file=",
    commandArgs(trailingOnly = FALSE),
    value = TRUE
  )

  if (length(file_arg) > 0) {
    script_path <- sub("^--file=", "", file_arg[[1]])

    if (identical(script_path, "-")) {
      return(normalizePath(
        getwd(),
        winslash = "/",
        mustWork = TRUE
      ))
    }

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

prepare_writable_directory <- function(path, label) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)

  if (!dir.exists(path)) {
    stop(
      label,
      " directory does not exist and could not be created: ",
      path,
      call. = FALSE
    )
  }

  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  probe <- tempfile(pattern = ".cycling-analytics-write-test-", tmpdir = path)
  writable <- tryCatch(
    file.create(probe),
    warning = function(w) FALSE,
    error = function(e) FALSE
  )

  if (isTRUE(writable)) {
    unlink(probe)
    return(path)
  }

  stop(
    label,
    " directory is not writable by the runtime user: ",
    path,
    call. = FALSE
  )
}

create_static_site_staging_dir <- function(output_dir) {
  staging_dir <- tempfile(
    pattern = ".cycling-analytics-staging-",
    tmpdir = output_dir
  )

  if (!dir.create(staging_dir, mode = "0700")) {
    stop(
      "Could not create dashboard staging directory: ",
      staging_dir,
      call. = FALSE
    )
  }

  normalizePath(staging_dir, winslash = "/", mustWork = TRUE)
}

static_site_dependency_references <- function(index_file) {
  html <- paste(readLines(index_file, warn = FALSE), collapse = "\n")
  matches <- gregexpr(
    "index_files/[^\\\"'<>[:space:]]+",
    html,
    perl = TRUE
  )
  references <- regmatches(html, matches)[[1]]

  if (identical(references, character(0))) {
    return(character())
  }

  unique(sub("[?#].*$", "", references))
}

validate_static_site <- function(site_dir) {
  index_file <- file.path(site_dir, "index.html")
  dependency_dir <- file.path(site_dir, "index_files")

  if (!file.exists(index_file) || is.na(file.info(index_file)$size) ||
      file.info(index_file)$size <= 0) {
    stop("Static-site artefact is missing a non-empty index.html.", call. = FALSE)
  }

  references <- static_site_dependency_references(index_file)
  if (length(references) == 0L) {
    stop(
      "Static-site index.html does not reference any index_files dependencies.",
      call. = FALSE
    )
  }

  if (!dir.exists(dependency_dir)) {
    stop(
      "Static-site index.html references index_files dependencies, but index_files/ is absent.",
      call. = FALSE
    )
  }

  missing_dependencies <- references[
    !file.exists(file.path(site_dir, references))
  ]
  if (length(missing_dependencies) > 0L) {
    stop(
      "Static-site artefact is missing referenced dependency file(s): ",
      paste(missing_dependencies, collapse = ", "),
      call. = FALSE
    )
  }

  invisible(list(
    index_file = index_file,
    dependency_dir = dependency_dir,
    dependency_references = references
  ))
}

static_site_entries <- function(path) {
  entries <- list.files(path, all.files = TRUE, no.. = TRUE)
  entries[!grepl("^\\.cycling-analytics-(staging|backup)-", entries)]
}

promote_static_site <- function(
  staging_dir,
  output_dir,
  step_hook = function(step) invisible(step)
) {
  validate_static_site(staging_dir)

  backup_dir <- tempfile(
    pattern = ".cycling-analytics-backup-",
    tmpdir = output_dir
  )
  if (!dir.create(backup_dir, mode = "0700")) {
    stop("Could not create static-site backup directory.", call. = FALSE)
  }

  old_entries <- static_site_entries(output_dir)
  new_entries <- static_site_entries(staging_dir)
  promoted_entries <- character()
  backed_up_entries <- character()
  committed <- FALSE

  on.exit({
    if (!committed) {
      for (entry in rev(promoted_entries)) {
        unlink(file.path(output_dir, entry), recursive = TRUE, force = TRUE)
      }
      for (entry in rev(backed_up_entries)) {
        file.rename(
          file.path(backup_dir, entry),
          file.path(output_dir, entry)
        )
      }
    }

    unlink(backup_dir, recursive = TRUE, force = TRUE)
    unlink(staging_dir, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  for (entry in old_entries) {
    moved <- file.rename(
      file.path(output_dir, entry),
      file.path(backup_dir, entry)
    )
    if (!moved) {
      stop("Could not back up current static-site entry: ", entry, call. = FALSE)
    }
    backed_up_entries <- c(backed_up_entries, entry)
  }

  # Publish index.html last. Until then, any reader sees the prior HTML or no
  # HTML rather than a new document referring to dependencies not yet present.
  promotion_order <- c(setdiff(new_entries, "index.html"), "index.html")
  for (entry in promotion_order) {
    moved <- file.rename(
      file.path(staging_dir, entry),
      file.path(output_dir, entry)
    )
    if (!moved) {
      stop("Could not promote static-site entry: ", entry, call. = FALSE)
    }
    promoted_entries <- c(promoted_entries, entry)
    step_hook(paste0("promoted:", entry))
  }

  validate_static_site(output_dir)
  committed <- TRUE
  invisible(output_dir)
}

render_dashboard_site <- function(
  input_file,
  staging_dir,
  render_dir,
  envir,
  quiet = FALSE
) {
  rmarkdown::render(
    input_file,
    output_file = "index.html",
    output_dir = staging_dir,
    intermediates_dir = render_dir,
    envir = envir,
    quiet = quiet
  )
}

get_dashboard_output_dir <- function(project_root) {
  configured_output <- Sys.getenv(
    "CYCLING_ANALYTICS_OUTPUT_DIR",
    unset = "output"
  )
  output_dir <- if (grepl("^/", configured_output)) {
    configured_output
  } else {
    file.path(project_root, configured_output)
  }

  prepare_writable_directory(output_dir, "Dashboard output")
}

get_application_config <- function(project_root) {
  run_mode <- Sys.getenv(
    "CYCLING_ANALYTICS_RUN_MODE",
    unset = "render"
  )
  allowed_run_modes <- "render"

  if (!run_mode %in% allowed_run_modes) {
    stop(
      "CYCLING_ANALYTICS_RUN_MODE must be one of: ",
      paste(allowed_run_modes, collapse = ", "),
      call. = FALSE
    )
  }

  timezone <- Sys.getenv(
    "CYCLING_ANALYTICS_TIMEZONE",
    unset = "Europe/London"
  )

  if (!timezone %in% OlsonNames()) {
    stop(
      "CYCLING_ANALYTICS_TIMEZONE is not a recognised timezone: ",
      timezone,
      call. = FALSE
    )
  }

  Sys.setenv(TZ = timezone)

  annual_goal <- Sys.getenv("ANNUAL_DISTANCE_GOAL_MI", unset = "")
  if (nzchar(annual_goal)) {
    annual_goal_value <- suppressWarnings(as.numeric(annual_goal))
    if (is.na(annual_goal_value) || annual_goal_value <= 0) {
      stop(
        "ANNUAL_DISTANCE_GOAL_MI must be a positive number when set.",
        call. = FALSE
      )
    }
  }

  output_dir <- get_dashboard_output_dir(project_root)

  configured_render <- Sys.getenv(
    "CYCLING_ANALYTICS_RENDER_DIR",
    unset = file.path(tempdir(), "cycling-analytics-render")
  )
  render_dir <- if (grepl("^/", configured_render)) {
    configured_render
  } else {
    file.path(project_root, configured_render)
  }
  render_dir <- prepare_writable_directory(
    render_dir,
    "R Markdown intermediate"
  )

  # Validate database values before connection retries begin.
  get_database_config()
  carto_basemap_api_key()

  list(
    run_mode = run_mode,
    timezone = timezone,
    output_dir = output_dir,
    render_dir = render_dir
  )
}

format_dashboard_number <- function(value, digits = 0) {
  format(
    round(value, digits),
    big.mark = ",",
    trim = TRUE,
    nsmall = digits
  )
}

get_latest_ride_summary <- function(activities) {
  latest_ride <- select_latest_ride(activities)

  if (nrow(latest_ride) == 0) {
    return("Latest ride: none")
  }

  distance_mi <- latest_ride$distance_metres * 0.000621371
  ride_date <- format(as.Date(latest_ride$start_date_local), "%d %b")

  glue::glue(
    "Latest ride: {format_dashboard_number(distance_mi, 1)} mi on {ride_date}"
  )
}

get_dashboard_next_refresh_text <- function() {
  supplied_text <- Sys.getenv("CYCLING_ANALYTICS_NEXT_REFRESH_TEXT", "")
  if (nzchar(supplied_text)) {
    return(supplied_text)
  }
  "not scheduled"
}

build_dashboard_refresh_summary <- function(rendered_at = Sys.time()) {
  glue::glue(
    "Last refresh: {format(rendered_at, '%H:%M')}<br>",
    "Next refresh: {get_dashboard_next_refresh_text()}"
  )
}

build_notification_context <- function(render_env, rendered_at) {
  ytd_stats <- render_env$ytd_stats

  ytd_distance <- get_ytd_values("distance_mi", ytd_stats)[["ytd"]]
  ytd_tons <- get_ytd_values("tons", ytd_stats)[["ytd"]]
  ytd_hours <- get_ytd_values("time_hr", ytd_stats)[["ytd"]]

  next_run_text <- get_dashboard_next_refresh_text()

  paste(
    glue::glue("Rendered: {format(rendered_at, '%d %b %H:%M')}"),
    glue::glue(
      "YTD: {format_dashboard_number(ytd_distance)} mi | {format_dashboard_number(ytd_tons)} tons | {format_dashboard_number(ytd_hours)} hr"
    ),
    get_latest_ride_summary(render_env$activities),
    glue::glue("Next refresh: {next_run_text}"),
    sep = "\n"
  )
}

main <- function() {
  # project setup -----------------------------------------------------------

  options(cycling_analytics_failed_stage = NULL)

  project_root <- NULL
  old_wd <- NULL
  application_config <- NULL

  run_dashboard_stage("Initialise", {
    project_root <- get_project_root()

    old_wd <- setwd(project_root)

    Sys.setenv(
      RENV_PROJECT = project_root,
      RENV_CONFIG_SANDBOX_ENABLED = "FALSE"
    )

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
        "lubridate",
        "rmarkdown",
        "tibble",
        "tidygeocoder",
        "glue",
        "htmlwidgets"
      ),
      project_root
    )

    # source runtime helpers ------------------------------------------------

    source(file.path(project_root, "db", "db.R"))
    source(file.path(project_root, "runtime_helpers.R"))
    source(file.path(project_root, "dashboard_functions.R"))
    source(file.path(project_root, "latest_ride_functions.R"))

    # environment -----------------------------------------------------------

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

    dashboard_log("Initialised runtime context:")
    dashboard_log(dashboard_runtime_context())
  })

  run_dashboard_stage("Validate configuration", {
    application_config <- get_application_config(project_root)
    dashboard_log(sprintf(
      "Application configuration: run_mode=%s; timezone=%s; output_dir=%s; render_dir=%s",
      application_config$run_mode,
      application_config$timezone,
      application_config$output_dir,
      application_config$render_dir
    ))
  })

  if (!is.null(old_wd)) {
    on.exit(setwd(old_wd), add = TRUE)
  }

  render_env <- new.env(parent = environment())

  on.exit(
    {
      cleanup_started_at <- Sys.time()
      dashboard_log(sprintf("Stage=Cleanup status=started cwd=%s", getwd()))

      tryCatch(
        {
          if (
            exists("con", envir = render_env, inherits = FALSE) &&
              DBI::dbIsValid(render_env$con)
          ) {
            log_message("Disconnecting database connection...")
            DBI::dbDisconnect(render_env$con)
          }

          dashboard_log(sprintf(
            "Stage=Cleanup status=success elapsed_seconds=%.1f cwd=%s",
            as.numeric(difftime(
              Sys.time(),
              cleanup_started_at,
              units = "secs"
            )),
            getwd()
          ))
        },
        error = function(e) {
          dashboard_log(sprintf(
            "Stage=Cleanup status=failed elapsed_seconds=%.1f cwd=%s",
            as.numeric(difftime(
              Sys.time(),
              cleanup_started_at,
              units = "secs"
            )),
            getwd()
          ))
          dashboard_log(sprintf("Stage=Cleanup error=%s", conditionMessage(e)))
        }
      )
    },
    add = TRUE
  )

  # Render application artefact --------------------------------------------

  staging_dir <- create_static_site_staging_dir(application_config$output_dir)
  on.exit(unlink(staging_dir, recursive = TRUE, force = TRUE), add = TRUE)

  run_dashboard_stage("Render dashboard", {
    render_dashboard_site(
      file.path(project_root, "dashboards", "index.Rmd"),
      staging_dir,
      application_config$render_dir,
      render_env
    )
  })

  run_dashboard_stage("Validate dashboard artefact", {
    validate_static_site(staging_dir)
  })

  run_dashboard_stage("Finalise dashboard artefact", {
    promote_static_site(staging_dir, application_config$output_dir)
  })

  notification_context_file <- Sys.getenv(
    "DASHBOARD_NOTIFICATION_CONTEXT_FILE",
    ""
  )

  if (nzchar(notification_context_file)) {
    writeLines(
      build_notification_context(render_env, Sys.time()),
      notification_context_file
    )
    dashboard_log(glue::glue(
      "Notification context written to {notification_context_file}."
    ))
  }

  dashboard_log(glue::glue(
    "Rendered dashboard artefact: {file.path(application_config$output_dir, 'index.html')}"
  ))

  run_dashboard_stage("Complete", {
    log_message("Dashboard refresh complete.")
  })
}

if (sys.nframe() == 0L) {
  tryCatch(
    main(),
    error = function(e) {
      stage_name <- getOption(
        "cycling_analytics_failed_stage",
        getOption("cycling_analytics_stage", "Unknown")
      )
      dashboard_log(sprintf(
        "Dashboard refresh failed in stage=%s exit_code=1 error=%s",
        stage_name,
        conditionMessage(e)
      ))
      quit(status = 1)
    }
  )
}
