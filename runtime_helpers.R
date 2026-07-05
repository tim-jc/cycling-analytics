log_message <- function(msg) {
  timestamp <- format(
    Sys.time(),
    "%Y-%m-%d %H:%M:%S"
  )

  message(
    glue::glue(
      "[{timestamp}] {msg}"
    )
  )

  flush.console()
}

install_cron_job <- function() {
  schedule <- Sys.getenv("SCRAPER_SCHEDULE")

  if (schedule == "") {
    stop("SCRAPER_SCHEDULE environment variable not set.")
  }

  scraper_path <- normalizePath(
    here::here("scraper.R"),
    winslash = "/"
  )

  log_path <- normalizePath(
    here::here("scraper.log"),
    winslash = "/"
  )

  existing <- tryCatch(
    system("crontab -l", intern = TRUE),
    error = function(e) character(0)
  )

  start_string <- "# >>> STRAVA_SCRAPER_START >>>"
  end_string <- "# <<< STRAVA_SCRAPER_END <<<"

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
    "## desc: Strava scraper update and dashboard refresh",
    glue::glue(
      "{schedule} /usr/local/bin/Rscript '{scraper_path}' cron >> '{log_path}' 2>&1"
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

  system2(
    "crontab",
    args = cron_file
  )

  log_message(
    glue::glue(
      "Cron schedule installed: {schedule}"
    )
  )
}

get_next_scraper_run <- function() {
  tz <- Sys.timezone()

  schedule <- Sys.getenv("SCRAPER_SCHEDULE")

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
  msg_url = "ntfy.sh/strava_stats_dashboard",
  msg_title = "Strava dashboard updated",
  msg_tags = "bike,chart_with_upwards_trend",
  msg_priority = "default",
  msg_link_url = "https://tim-jc.github.io/strava_scraper"
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
  git_path = here::here(),
  file_to_publish = "docs/index.html",
  commit_msg = "auto commit from cron / Rscript"
) {
  git_cmd <- stringr::str_glue(
    "
    cd '{git_path}' &&
    git add '{file_to_publish}' &&
    git commit -m '{commit_msg}' &&
    git push origin main
    "
  )

  result <- system(
    git_cmd,
    intern = TRUE,
    ignore.stderr = FALSE
  )

  print(result)
}
