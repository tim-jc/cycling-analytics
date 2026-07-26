#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(plotly)
  library(flexdashboard)
})

Sys.setenv(TZ = "Europe/London")

source("db/db.R")
source("dashboard_functions.R")

tests_run <- 0L

run_test <- function(name, code) {
  force(code)
  tests_run <<- tests_run + 1L
  cat(sprintf("PASS: %s\n", name))
}

expect_true <- function(value, message = "Expected TRUE") {
  if (!isTRUE(value)) {
    stop(message, call. = FALSE)
  }
}

expect_equal <- function(actual, expected, tolerance = 1e-8) {
  if (!isTRUE(all.equal(actual, expected, tolerance = tolerance))) {
    stop(
      "Expected ",
      paste(expected, collapse = ", "),
      "; got ",
      paste(actual, collapse = ", "),
      call. = FALSE
    )
  }
}

expect_error <- function(code, pattern) {
  error_message <- tryCatch(
    {
      force(code)
      NA_character_
    },
    error = conditionMessage
  )

  if (is.na(error_message) || !grepl(pattern, error_message, fixed = TRUE)) {
    stop(
      "Expected error containing '",
      pattern,
      "'; got ",
      ifelse(is.na(error_message), "no error", error_message),
      call. = FALSE
    )
  }
}

metres_per_mile <- 1 / 0.000621371
reference_date <- as.Date("2026-07-26")

activities <- tibble(
  activity_id = c(1, 2, 3),
  is_trainer = c(FALSE, FALSE, TRUE),
  sport_type = c("Ride", "Ride", "VirtualRide"),
  start_date_local = as.Date(c("2026-07-20", "2026-07-21", "2025-07-20")),
  distance_metres = c(10, 20, 5) * metres_per_mile,
  moving_time_seconds = c(3600, 7200, 1800),
  elevation_gain_metres = c(100, 200, 0),
  energy_kilojoules = c(500, NA, 250)
)

streams <- tibble(
  activity_id = 1,
  sport_type = "Ride",
  start_date_local = as.Date("2026-07-20"),
  latitude = 51.5,
  longitude = -0.1,
  stream_order = 1L
)

run_test("activity without streams remains in the activity summary", {
  summary <- build_activity_summary(activities)

  expect_equal(nrow(summary), 3L)
  expect_true(2 %in% summary$activity_id)
  expect_true(!2 %in% streams$activity_id)
  expect_equal(
    sum(summary$distance_mi[year(summary$start_date_local) == 2026]),
    30
  )
})

run_test("activity without streams contributes to YTD totals", {
  ytd <- build_ytd_stats(activities, reference_date = reference_date)
  current <- ytd |>
    filter(yr == 2026, ytd_val)

  expect_equal(current$ytd_distance_mi, 30)
  expect_equal(current$ytd_time_hr, 3)
  expect_equal(current$ytd_elevation_m, 300)
})

run_test("calendar-year boundary keeps current and previous year separate", {
  boundary_activities <- activities |>
    slice(1:2) |>
    mutate(
      start_date_local = as.Date(c("2025-12-31", "2026-01-01")),
      distance_metres = c(10, 20) * metres_per_mile
    )
  ytd <- build_ytd_stats(
    boundary_activities,
    reference_date = as.Date("2026-01-01")
  )

  expect_equal(
    ytd |> filter(yr == 2026, ytd_val) |> pull(ytd_distance_mi),
    20
  )
  expect_equal(
    ytd |> filter(yr == 2025) |> summarise(value = max(yr_distance_mi)) |> pull(value),
    10
  )
})

run_test("empty weekly periods are represented as zero", {
  summary <- build_activity_summary(activities |> slice(1))
  weekly <- build_weekly_training_volume(
    summary,
    completed_weeks = 4,
    reference_date = reference_date
  )

  expect_equal(nrow(weekly), 5L)
  expect_equal(sum(weekly$distance_mi == 0), 4L)
  expect_equal(sum(weekly$is_current_week), 1L)
})

run_test("missing power remains missing in presentation smoothing", {
  best_efforts <- tibble(
    activity_id = 1,
    duration_seconds = 600,
    start_sample_index = 1,
    end_sample_index = 2
  )
  effort_streams <- tibble(
    activity_id = c(1, 1),
    duration_seconds = c(600, 600),
    stream_order = c(1, 2),
    distance_metres = c(0, 100),
    watts = c(NA_real_, NA_real_)
  )
  prepared <- prepare_best_effort_stream(
    effort_streams,
    best_efforts,
    duration_seconds = 600
  )

  expect_true(all(is.na(prepared$power_smooth)))
})

run_test("empty outdoor streams return four placeholder extrema", {
  empty_streams <- tibble(
    sport_type = character(),
    latitude = double(),
    longitude = double()
  )
  extrema <- get_position_extremities(empty_streams)

  expect_equal(extrema$extremity, c("N", "S", "E", "W"))
})

run_test("missing database configuration fails before connection retries", {
  database_keys <- c(
    "MARIADB_HOST",
    "MARIADB_PORT",
    "MARIADB_NAME",
    "MARIADB_USER",
    "MARIADB_PASSWORD"
  )
  old_values <- Sys.getenv(database_keys, unset = NA_character_)
  on.exit({
    Sys.unsetenv(database_keys)
    present <- !is.na(old_values)
    if (any(present)) {
      do.call(
        Sys.setenv,
        as.list(stats::setNames(old_values[present], database_keys[present]))
      )
    }
  }, add = TRUE)

  Sys.unsetenv(database_keys)
  expect_error(
    get_database_config(),
    "Missing required database configuration"
  )

  Sys.setenv(
    MARIADB_HOST = "database",
    MARIADB_PORT = "not-a-port",
    MARIADB_NAME = "cycling",
    MARIADB_USER = "reader",
    MARIADB_PASSWORD = "test-only"
  )
  expect_error(
    get_database_config(),
    "MARIADB_PORT must be an integer between 1 and 65535."
  )
})

cat(sprintf("\n%d tests passed.\n", tests_run))
