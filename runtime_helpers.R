log_message <- function(msg) {
  timestamp <- format(
    Sys.time(),
    "%Y-%m-%d %H:%M:%S"
  )

  log_line <- glue::glue("[{timestamp}] {msg}")

  message(log_line)

  if (identical(Sys.getenv("DASHBOARD_LOG_REDIRECTED", ""), "TRUE")) {
    flush.console()
    return(invisible(TRUE))
  }

  log_file <- Sys.getenv("DASHBOARD_LOG", "")

  if (!nzchar(log_file)) {
    project_root <- Sys.getenv("RENV_PROJECT", "")

    if (nzchar(project_root)) {
      log_file <- file.path(project_root, "dashboard_refresh.log")
    }
  }

  if (nzchar(log_file)) {
    tryCatch(
      suppressWarnings(
        cat(log_line, "\n", file = log_file, append = TRUE)
      ),
      error = function(e) {
        message(glue::glue(
          "[{timestamp}] Log file append skipped: {conditionMessage(e)}"
        ))
      }
    )
  }

  flush.console()
}

install_cron_job <- function(project_path = getwd()) {
  schedule <- Sys.getenv("DASHBOARD_REFRESH_SCHEDULE")

  if (schedule == "") {
    stop("DASHBOARD_REFRESH_SCHEDULE environment variable not set.")
  }

  dashboard_runner_path <- normalizePath(
    file.path(project_path, "scripts", "run_dashboard_refresh.sh"),
    winslash = "/",
    mustWork = TRUE
  )

  project_path <- normalizePath(
    project_path,
    winslash = "/",
    mustWork = TRUE
  )

  normalizePath(
    file.path(project_path, "render_dashboard.R"),
    winslash = "/",
    mustWork = TRUE
  )

  existing <- tryCatch(
    system("crontab -l", intern = TRUE),
    error = function(e) character(0)
  )

  start_string <- "# >>> CYCLING_ANALYTICS_START >>>"
  end_string <- "# <<< CYCLING_ANALYTICS_END <<<"

  remove_start <- match(start_string, existing)
  remove_end <- match(end_string, existing)

  if (xor(is.na(remove_start), is.na(remove_end))) {
    stop("Managed cron block appears corrupted.")
  }

  if (!is.na(remove_start)) {
    cron_to_keep <- existing[-(remove_start:remove_end)]
  } else {
    cron_to_keep <- existing
  }

  cron_to_keep <- cron_to_keep[cron_to_keep != ""]

  cron_block <- c(
    "",
    start_string,
    "## desc: Cycling Analytics dashboard refresh",
    glue::glue(
      "{schedule} '{dashboard_runner_path}'"
    ),
    end_string
  )

  cron_to_write <- c(
    cron_to_keep,
    cron_block
  )

  cron_file <- tempfile(fileext = ".cron")

  writeLines(
    cron_to_write,
    cron_file
  )

  crontab_output <- suppressWarnings(system2(
    "crontab",
    args = cron_file,
    stdout = TRUE,
    stderr = TRUE
  ))

  crontab_status <- attr(
    crontab_output,
    "status",
    exact = TRUE
  )

  if (is.null(crontab_status)) {
    crontab_status <- 0L
  }

  if (!identical(crontab_status, 0L)) {
    stop(
      "crontab install failed with status ",
      crontab_status,
      if (length(crontab_output) > 0) {
        paste0(":\n", paste(crontab_output, collapse = "\n"))
      } else {
        ""
      },
      call. = FALSE
    )
  }

  log_message(
    glue::glue(
      "Cron schedule installed: {schedule}"
    )
  )
}

get_next_dashboard_run <- function() {
  tz <- Sys.timezone()

  schedule <- Sys.getenv("DASHBOARD_REFRESH_SCHEDULE")

  if (schedule == "") {
    return(as.POSIXct(NA))
  }

  schedule <- str_split_1(schedule, pattern = " ")

  mins <- schedule[1]

  hours <- str_split_1(schedule[2], ",")

  runs <- bind_rows(
    tibble(hours, mins, date = Sys.Date()),
    tibble(hours, mins, date = Sys.Date() + days(1)),
  ) %>%
    mutate(dt = lubridate::ymd_hm(str_c(date, hours, mins), tz = tz)) %>%
    filter(dt > now())

  next_run <- min(runs$dt)

  return(next_run)
}

send_ntfy_message <- function(
  msg_body,
  msg_url = "ntfy.sh/cycling-analytics",
  msg_title = "Dashboard updated",
  msg_tags = "bike,chart_with_upwards_trend",
  msg_priority = "default",
  msg_link_url = "https://tim-jc.github.io/cycling-analytics"
) {
  # Allowed priorities
  allowed_priorites <- c("urgent", "high", "default", "low", "min")

  if (!msg_priority %in% allowed_priorites) {
    stop(str_glue(
      "Invalid priority level supplied; allowed values are '{str_flatten(allowed_priorites, collapse = \"', '\")}'"
    ))
  }

  # tags - if they match an emoji short code they'll be rendered as such, otherwise will appear as string
  # tags should be supplied as a single string value with commas separating tags
  response <- httr::POST(
    url = msg_url,
    body = msg_body,
    httr::add_headers(c(
      "Title" = msg_title,
      "Tags" = msg_tags,
      "Priority" = msg_priority,
      "Click" = msg_link_url
    ))
  )

  return(response)
}

publish_to_git <- function(
  git_path = getwd(),
  file_to_publish = "docs/index.html",
  commit_msg = "auto commit from cron / Rscript"
) {
  run_git <- function(args) {
    started_at <- Sys.time()
    command <- paste(c("git", args), collapse = " ")

    log_message(glue::glue(
      "Git command started: cwd={git_path}; command={command}"
    ))

    result <- suppressWarnings(
      withr::with_dir(
        git_path,
        system2(
          "git",
          args = shQuote(args),
          stdout = TRUE,
          stderr = TRUE
        )
      )
    )

    status <- attr(result, "status")
    if (is.null(status)) {
      status <- 0
    }

    log_message(glue::glue(
      "Git command finished: status={status}; elapsed_seconds={round(as.numeric(difftime(Sys.time(), started_at, units = 'secs')), 1)}; command={command}"
    ))

    list(output = result, status = status)
  }

  check_git <- function(args, label) {
    result <- run_git(args)

    if (length(result$output) > 0) {
      message(paste(result$output, collapse = "\n"))
    }

    if (result$status != 0) {
      stop(label, " failed with status ", result$status, call. = FALSE)
    }

    invisible(result)
  }

  check_git(c("add", file_to_publish), "git add")

  diff_result <- run_git(c("diff", "--cached", "--quiet"))

  if (diff_result$status == 0) {
    message("No dashboard changes to commit.")
    check_git(c("push", "origin", "main"), "git push")
    return(invisible(list(
      committed = FALSE,
      pushed = TRUE,
      commit = NA_character_
    )))
  }

  check_git(c("commit", "-m", commit_msg), "git commit")
  commit_hash <- run_git(c("rev-parse", "--short", "HEAD"))$output[[1]]
  check_git(c("push", "origin", "main"), "git push")

  message("Published dashboard to GitHub.")
  invisible(list(
    committed = TRUE,
    pushed = TRUE,
    commit = commit_hash
  ))
}

check_cron_schedule <- function() {
  environ_schedule <- Sys.getenv("DASHBOARD_REFRESH_SCHEDULE")

  cron <- tryCatch(
    system("crontab -l", intern = TRUE),
    error = function(e) character(0)
  )

  start_index <- match(
    "# >>> CYCLING_ANALYTICS_START >>>",
    cron
  )

  if (is.na(start_index)) {
    return(FALSE)
  }

  cron_line <- cron[start_index + 2]

  cron_schedule <- str_split_1(
    cron_line,
    "\\s+"
  ) |>
    (\(x) paste(x[1:5], collapse = " "))()

  match <- identical(
    environ_schedule,
    cron_schedule
  )

  if (!match) {
    log_message(
      "Mismatch between cron and .Renviron schedule. Run install_cron_job() to reset to .Renviron values"
    )
  }

  return(match)
}
