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
source("latest_ride_functions.R")
source("reports/ride-summary/R/ride_report_model.R")

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

latest_ride_fixture <- tibble(
  activity_id = c(1, 2, 3, 4),
  sport_type = c("Ride", "Ride", "VirtualRide", "Run"),
  start_datetime_local = as.POSIXct(c(
    "2026-07-20 08:00:00", "2026-07-22 08:00:00",
    "2026-07-23 08:00:00", "2026-07-24 08:00:00"
  )),
  distance_metres = c(19.9, 20, 30, 50) * METRES_PER_MILE
)

run_test("Latest Ride skips a newer activity under 20 miles", {
  fixture <- latest_ride_fixture |> dplyr::filter(.data$activity_id %in% c(1, 2))
  selected <- select_latest_significant_activity(fixture)
  expect_equal(selected$activity_id, 2)
})

run_test("Latest Ride includes exactly 20 miles", {
  selected <- select_latest_significant_activity(latest_ride_fixture |> dplyr::slice(2))
  expect_equal(selected$activity_id, 2)
})

run_test("Latest Ride chooses the newest qualifying cycling activity", {
  selected <- select_latest_significant_activity(latest_ride_fixture)
  expect_equal(selected$activity_id, 3)
})

run_test("Latest Ride excludes non-cycling activities", {
  selected <- select_latest_significant_activity(latest_ride_fixture |> dplyr::slice(4))
  expect_equal(nrow(selected), 0L)
})

run_test("Latest Ride has an explicit empty state with the selection rule", {
  selected <- select_latest_significant_activity(latest_ride_fixture |> dplyr::slice(1))
  expect_equal(nrow(selected), 0L)
  expect_true(grepl("at least 20 miles", latest_ride_empty_message(), fixed = TRUE))
})

run_test("missing one Latest Ride stream does not suppress other traces", {
  partial_streams <- tibble(
    altitude_metres = c(100, 105), watts = c(NA_real_, NA_real_),
    heartrate_bpm = c(130, 135), latitude = c(51.5, 51.6), longitude = c(-0.1, -0.2)
  )
  availability <- latest_ride_stream_availability(partial_streams)
  expect_true(availability[["elevation"]])
  expect_true(!availability[["power"]])
  expect_true(availability[["heart_rate"]])
  expect_true(availability[["gps"]])
})

run_test("a qualifying Latest Ride remains usable without streams", {
  selected <- select_latest_significant_activity(latest_ride_fixture |> dplyr::slice(2)) |>
    dplyr::mutate(activity_name = "Fixture ride")
  availability <- latest_ride_stream_availability(empty_latest_ride_streams())
  expect_equal(nrow(selected), 1L)
  expect_true(all(!availability))
  expect_true(inherits(latest_ride_identity(selected), "shiny.tag"))
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

run_test("ride report selects only the eligible 20-minute effort", {
  efforts <- tibble(
    activity_id = 1,
    duration_seconds = c(1200L, 300L, 60L),
    peak_value = c(220, 280, 360),
    start_sample_index = c(1L, 100L, 2000L),
    end_sample_index = c(1200L, 399L, 2059L),
    start_distance_metres = c(0, 1000, 20000),
    end_distance_metres = c(10000, 4000, 20500)
  )
  selected <- select_coaching_efforts(efforts)

  expect_equal(selected$duration_seconds, 1200L)
})

run_test("ride report power zones degrade gracefully without FTP", {
  report_streams <- tibble(watts = rep(200, 120))
  expect_equal(nrow(build_power_zones(report_streams)), 0L)
})

run_test("ride report excludes discontinuous Gold effort windows", {
  efforts <- tibble(
    duration_seconds = c(60L, 1200L),
    start_time_seconds = c(100L, 1000L),
    end_time_seconds = c(159L, 2500L)
  )
  continuous <- filter_continuous_efforts(efforts)

  expect_equal(continuous$duration_seconds, 60L)
})

run_test("ride report effort trace includes 30-second context", {
  streams <- tibble(
    sample_index = 1:181,
    time_seconds = 0:180,
    distance_metres = 0:180,
    altitude_metres = 100,
    watts = 200,
    heartrate_bpm = 140,
    cadence_rpm = 85
  )
  effort <- tibble(
    effort_name = "Best 1 min power",
    start_sample_index = 61L,
    end_sample_index = 121L,
    start_time_seconds = 60L,
    end_time_seconds = 120L,
    start_distance_metres = 60,
    end_distance_metres = 120,
    duration_seconds = 60L,
    peak_value = 200
  )
  model <- build_effort_summary(effort, streams)

  expect_equal(range(model$context_streams$relative_time_minutes), c(-0.5, 1.5))
})

cat(sprintf("\n%d tests passed.\n", tests_run))
