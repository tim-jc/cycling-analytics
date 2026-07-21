# build cycling-analytics dashboard

dashboard_timestamp <- function() {
  format(Sys.time(), "%Y-%m-%d %H:%M:%S")
}

dashboard_log_path <- function() {
  configured_log <- Sys.getenv("DASHBOARD_LOG", "")

  if (nzchar(configured_log)) {
    return(configured_log)
  }

  project_root <- Sys.getenv("RENV_PROJECT", "")

  if (!nzchar(project_root)) {
    project_root <- tryCatch(
      get_project_root(),
      error = function(e) getwd()
    )
  }

  file.path(project_root, "dashboard_refresh.log")
}

dashboard_log <- function(msg) {
  log_lines <- sprintf("[%s] %s", dashboard_timestamp(), msg)

  message(log_lines)

  log_file <- tryCatch(
    dashboard_log_path(),
    error = function(e) NA_character_
  )

  if (!is.na(log_file) && nzchar(log_file)) {
    cat(
      paste(log_lines, collapse = "\n"),
      "\n",
      file = log_file,
      append = TRUE
    )
  }

  flush.console()
}

dashboard_runtime_context <- function() {
  paste(
    sprintf("cwd=%s", getwd()),
    sprintf("PATH=%s", Sys.getenv("PATH", "")),
    sprintf("HOME=%s", Sys.getenv("HOME", "")),
    sprintf("SHELL=%s", Sys.getenv("SHELL", "")),
    sprintf(".libPaths()=%s", paste(.libPaths(), collapse = " | ")),
    sep = "\n"
  )
}

run_dashboard_stage <- function(stage_name, expr) {
  started_at <- Sys.time()
  options(cycling_analytics_stage = stage_name)

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
      dashboard_log(sprintf(
        "Stage=%s status=failed elapsed_seconds=%.1f cwd=%s",
        stage_name,
        as.numeric(difftime(Sys.time(), started_at, units = "secs")),
        getwd()
      ))
      dashboard_log(sprintf("Stage=%s error=%s", stage_name, conditionMessage(e)))
      dashboard_log("Failure context:")
      dashboard_log(dashboard_runtime_context())
      stop(e)
    }
  )
}

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

format_dashboard_number <- function(value, digits = 0) {
  format(
    round(value, digits),
    big.mark = ",",
    trim = TRUE,
    nsmall = digits
  )
}

get_latest_ride_summary <- function(activity_streams) {
  latest_ride <- activity_streams |>
    dplyr::filter(.data$sport_type == "Ride") |>
    dplyr::select(
      "activity_id",
      "start_date_local",
      "distance_metres"
    ) |>
    dplyr::distinct() |>
    dplyr::arrange(dplyr::desc(.data$start_date_local)) |>
    dplyr::slice_head(n = 1)

  if (nrow(latest_ride) == 0) {
    return("Latest ride: none")
  }

  distance_mi <- latest_ride$distance_metres * 0.000621371
  ride_date <- format(as.Date(latest_ride$start_date_local), "%d %b")

  glue::glue(
    "Latest ride: {format_dashboard_number(distance_mi, 1)} mi on {ride_date}"
  )
}

get_publish_summary <- function(publish_result) {
  if (isTRUE(publish_result$committed)) {
    return(glue::glue("Publish: commit {publish_result$commit} pushed"))
  }

  "Publish: no dashboard changes"
}

build_success_notification <- function(render_env, publish_result, rendered_at) {
  ytd_stats <- render_env$ytd_stats

  ytd_distance <- get_ytd_values("distance_mi", ytd_stats)[["ytd"]]
  ytd_tons <- get_ytd_values("tons", ytd_stats)[["ytd"]]
  ytd_hours <- get_ytd_values("time_hr", ytd_stats)[["ytd"]]

  next_run <- get_next_dashboard_run()
  next_run_text <- if (is.na(next_run)) {
    "not scheduled"
  } else {
    format(next_run, "%H:%M")
  }

  paste(
    glue::glue("Rendered: {format(rendered_at, '%d %b %H:%M')}"),
    glue::glue(
      "YTD: {format_dashboard_number(ytd_distance)} mi | {format_dashboard_number(ytd_tons)} tons | {format_dashboard_number(ytd_hours)} hr"
    ),
    get_latest_ride_summary(render_env$activity_streams),
    get_publish_summary(publish_result),
    glue::glue("Next refresh: {next_run_text}"),
    sep = "\n"
  )
}

main <- function() {
  # project setup -----------------------------------------------------------

  project_root <- NULL
  old_wd <- NULL

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

    # source runtime helpers ------------------------------------------------

    source(file.path(project_root, "db", "db.R"))
    source(file.path(project_root, "runtime_helpers.R"))
    source(file.path(project_root, "dashboard_functions.R"))

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
          if (exists("con", envir = render_env, inherits = FALSE) &&
              DBI::dbIsValid(render_env$con)) {
            log_message("Disconnecting database connection...")
            DBI::dbDisconnect(render_env$con)
          }

          dashboard_log(sprintf(
            "Stage=Cleanup status=success elapsed_seconds=%.1f cwd=%s",
            as.numeric(difftime(Sys.time(), cleanup_started_at, units = "secs")),
            getwd()
          ))
        },
        error = function(e) {
          dashboard_log(sprintf(
            "Stage=Cleanup status=failed elapsed_seconds=%.1f cwd=%s",
            as.numeric(difftime(Sys.time(), cleanup_started_at, units = "secs")),
            getwd()
          ))
          dashboard_log(sprintf("Stage=Cleanup error=%s", conditionMessage(e)))
        }
      )
    },
    add = TRUE
  )

  # Render and publish ------------------------------------------------------

  # Render dashboard
  run_dashboard_stage("Render dashboard", {
    rmarkdown::render(
      file.path(project_root, "dashboards", "index.Rmd"),
      output_file = "index.html",
      output_dir = file.path(project_root, "docs"),
      envir = render_env
    )
  })

  # Push updated dashboard to git
  publish_result <- run_dashboard_stage("Publish to Git", {
    publish_to_git(git_path = project_root)
  })

  # Send notification
  run_dashboard_stage("Notify", {
    ntfy_msg <- build_success_notification(
      render_env,
      publish_result,
      Sys.time()
    )

    msg_title <- if (isTRUE(publish_result$committed)) {
      "Dashboard published"
    } else {
      "Dashboard checked"
    }

    msg_tags <- if (isTRUE(publish_result$committed)) {
      "bike,white_check_mark"
    } else {
      "bike,mag"
    }

    send_ntfy_message(
      ntfy_msg,
      msg_title = msg_title,
      msg_tags = msg_tags
    )
  })

  run_dashboard_stage("Complete", {
    log_message("Dashboard refresh complete.")
  })
}

tryCatch(
  main(),
  error = function(e) {
    stage_name <- getOption("cycling_analytics_stage", "Unknown")
    dashboard_log(sprintf(
      "Dashboard refresh failed in stage=%s exit_code=1 error=%s",
      stage_name,
      conditionMessage(e)
    ))
    quit(status = 1)
  }
)
