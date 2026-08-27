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
source("reports/ride-summary/R/ride_report_components.R")
source("render_dashboard.R")

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

run_test("container logging defaults to stdout without a log file", {
  withr::local_envvar(c(
    DASHBOARD_LOG = NA,
    RENV_PROJECT = "/opt/cycling-analytics"
  ))

  expect_true(is.na(dashboard_log_path()))
})

run_test("writable runtime directories are accepted and probed cleanly", {
  parent_dir <- withr::local_tempdir()
  runtime_dir <- file.path(parent_dir, "render")

  prepared <- prepare_writable_directory(runtime_dir, "Test runtime")

  expect_equal(prepared, normalizePath(runtime_dir))
  expect_equal(
    list.files(runtime_dir, all.files = TRUE, no.. = TRUE),
    character()
  )
})

run_test("nested dashboard stages restore the outer failure context", {
  old_stage <- getOption("cycling_analytics_stage", NULL)
  on.exit(options(cycling_analytics_stage = old_stage), add = TRUE)
  options(cycling_analytics_stage = "Outer stage")

  run_dashboard_stage("Inner stage", {
    expect_equal(getOption("cycling_analytics_stage"), "Inner stage")
  })

  expect_equal(getOption("cycling_analytics_stage"), "Outer stage")
})

run_test("failed dashboard stage remains available to the final handler", {
  old_failed_stage <- getOption("cycling_analytics_failed_stage", NULL)
  on.exit(
    options(cycling_analytics_failed_stage = old_failed_stage),
    add = TRUE
  )
  options(cycling_analytics_failed_stage = NULL)

  tryCatch(
    run_dashboard_stage("Render dashboard", stop("file connection failed")),
    error = function(e) NULL
  )

  expect_equal(
    getOption("cycling_analytics_failed_stage"),
    "Render dashboard"
  )
})

run_test("missing CARTO key gives an actionable, non-secret error", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = NA)
  error_message <- tryCatch(
    carto_basemap_api_key(),
    error = conditionMessage
  )

  expect_true(grepl("CARTO_BASEMAP_API_KEY", error_message, fixed = TRUE))
  expect_true(!grepl("test-carto-key", error_message, fixed = TRUE))
})

run_test("CARTO tile URL preserves the Voyager basemap and adds the key", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  tile_url <- carto_basemap_tile_url("voyager_labels_under")

  expect_equal(
    tile_url,
    paste0(
      "https://{s}.basemaps.cartocdn.com/",
      "rastertiles/voyager_labels_under/{z}/{x}/{y}.png?key=test-carto-key"
    )
  )
})

run_test("CARTO tile URL preserves the Positron basemap", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")

  expect_true(grepl(
    "/light_all/{z}/{x}/{y}.png?key=test-carto-key",
    carto_basemap_tile_url("positron"),
    fixed = TRUE
  ))
})

run_test("CARTO configuration does not print the configured key", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  output <- capture.output(api_key <- carto_basemap_api_key())

  expect_equal(output, character())
  expect_equal(api_key, "test-carto-key")
})

metres_per_mile <- 1 / 0.000621371
reference_date <- as.Date("2026-07-26")

activities <- tibble(
  activity_id = c(1, 2, 3),
  is_trainer = c(FALSE, FALSE, TRUE),
  sport_type = c("Ride", "Ride", "VirtualRide"),
  start_datetime_local = as.POSIXct(c(
    "2026-07-20 08:00:00", "2026-07-21 08:00:00", "2025-07-20 08:00:00"
  )),
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

run_test("latest ride uses start time when rides share a date", {
  same_day <- tibble(
    activity_id = c(19501207283, 19502918454),
    sport_type = c("Ride", "Ride"),
    start_datetime_local = as.POSIXct(c(
      "2026-07-28 05:13:09", "2026-07-28 17:18:51"
    )),
    start_date_local = as.Date(c("2026-07-28", "2026-07-28")),
    distance_metres = c(213806, 13047.5)
  )
  latest <- select_latest_ride(same_day)

  expect_equal(latest$activity_id, 19502918454)
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
  identity <- latest_ride_identity(selected)
  identity_html <- as.character(identity)
  expect_true(inherits(identity, "shiny.tag"))
  expect_true(grepl("Fixture ride", identity_html, fixed = TRUE))
  expect_true(grepl("Wednesday 22 July 2026, 08:00", identity_html, fixed = TRUE))
  expect_true(grepl("https://www.strava.com/activities/2", identity_html, fixed = TRUE))
})

run_test("Latest Ride HR zones use an explicit configured maximum", {
  zone_streams <- tibble(heartrate_bpm = c(100, 120, 140, 160, 180))
  zones <- build_latest_ride_hr_zones(zone_streams, max_hr_bpm = 200)
  expect_equal(as.character(zones$zone), paste0("Z", 1:5))
  expect_equal(sum(zones$seconds), 5)
  expect_equal(nrow(build_latest_ride_hr_zones(zone_streams, max_hr_bpm = NA_real_)), 0L)
})

run_test("Latest Ride highlights favour activity and strong power rankings", {
  rankings <- tibble(
    achievement_rank = c(4, 2, 1, 12),
    comparison_count = c(100, 20, 100, 100),
    ranking_type = c("distance", "speed_50_miles", "power", "power"),
    duration_seconds = c(0, 0, 1800, 300),
    metric_value = c(200000, 20, 230, 250)
  )
  rendered <- as.character(latest_ride_highlights(rankings))
  expect_true(grepl("4th longest ride this year", rendered, fixed = TRUE))
  expect_true(grepl("2nd fastest 50+ mile ride this year", rendered, fixed = TRUE))
  expect_true(grepl("1st best 30 min power this year", rendered, fixed = TRUE))
  expect_true(!grepl("12th", rendered, fixed = TRUE))
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

coaching_lap_fixture <- function(
  power_ratio,
  elevation_gain = 0,
  vam = 0,
  duration = 1200,
  telemetry = TRUE,
  names = paste("Lap", seq_along(power_ratio))
) {
  count <- length(power_ratio)
  tibble(
    lap_id = seq_len(count),
    activity_id = 1,
    lap_index = seq_len(count),
    effort_name = names,
    elapsed_time_seconds = duration,
    moving_time_seconds = duration,
    distance_metres = duration * 8,
    start_sample_index = seq(1, by = 2000, length.out = count),
    end_sample_index = start_sample_index + duration - 1,
    start_time_seconds = seq(0, by = 2000, length.out = count),
    end_time_seconds = start_time_seconds + duration,
    start_distance_metres = seq(0, by = 10000, length.out = count),
    end_distance_metres = start_distance_metres + distance_metres,
    average_speed_miles_per_hour = 18,
    average_cadence_rpm = 85,
    average_power_watts = 180 * power_ratio,
    normalized_power_watts = NA_real_,
    average_heartrate_bpm = 145,
    elevation_gain_metres = elevation_gain,
    vam_metres_per_hour = vam,
    net_elevation_change_metres = elevation_gain,
    telemetry_sample_count = ifelse(telemetry, duration, 0),
    telemetry_available = telemetry,
    ride_average_power_watts = 180,
    power_ratio = power_ratio
  )
}

run_test("interval ride selects several coaching efforts", {
  laps <- coaching_lap_fixture(
    c(0.75, 1.30, 0.55, 1.25, 0.55, 1.20, 0.70),
    names = c(
      "Warm up", "Interval 1", "Recovery", "Interval 2",
      "Recovery 2", "Threshold", "Cool down"
    )
  )
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, c("Interval 1", "Interval 2", "Threshold"))
})

run_test("mountain ride selects principal climbs without duplicates", {
  laps <- coaching_lap_fixture(
    power_ratio = c(0.95, 0.90, 1.02),
    elevation_gain = c(420, 20, 280),
    vam = c(720, 80, 650),
    duration = c(2100, 600, 1500),
    names = c("Long climb", "Descent", "Steep climb")
  )
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, c("Long climb", "Steep climb"))
  expect_equal(length(unique(selected$lap_id)), nrow(selected))
})

run_test("steady endurance ride selects no individual efforts", {
  laps <- coaching_lap_fixture(rep(1, 6), duration = rep(3600, 6))
  expect_equal(nrow(select_coaching_efforts(laps)), 0L)
})

run_test("incomplete lap telemetry degrades without selecting an effort", {
  laps <- coaching_lap_fixture(c(1.35, 1.25), telemetry = c(FALSE, TRUE))
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$lap_id, 2L)
})

run_test("many high-quality laps are limited to five effort pages", {
  laps <- coaching_lap_fixture(seq(1.15, 1.42, length.out = 10))
  selected <- select_coaching_efforts(laps)

  expect_equal(nrow(selected), 5L)
  expect_equal(length(unique(selected$lap_id)), 5L)
})

run_test("coherent work sets retain every recovery-separated effort", {
  work_ratios <- c(1.42, 1.46, 1.49, 1.47, 1.48, 1.48, 1.48, 1.47)
  ratios <- as.vector(rbind(work_ratios, rep(0.65, length(work_ratios))))
  durations <- as.vector(rbind(
    c(219, 121, 334, 194, 193, 517, 191, 309),
    rep(180, length(work_ratios))
  ))
  names <- as.vector(rbind(
    paste("Work", seq_along(work_ratios)),
    paste("Recovery", seq_along(work_ratios))
  ))
  laps <- coaching_lap_fixture(ratios, duration = durations, names = names)
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, paste("Work", seq_along(work_ratios)))
})

run_test("coherent work sets respect the ten-effort hard ceiling", {
  work_count <- 12L
  ratios <- as.vector(rbind(rep(1.35, work_count), rep(0.65, work_count)))
  names <- as.vector(rbind(
    paste("Work", seq_len(work_count)),
    paste("Recovery", seq_len(work_count))
  ))
  laps <- coaching_lap_fixture(ratios, duration = 240, names = names)
  selected <- select_coaching_efforts(laps)

  expect_equal(nrow(selected), 10L)
  expect_equal(selected$effort_name, paste("Work", seq_len(10)))
})

run_test("selected laps receive coaching interval names", {
  selected <- coaching_lap_fixture(c(1.3, 1.2), names = c("Lap 8", "Lap 10")) |>
    prepare_coaching_effort_presentation()

  expect_equal(
    selected$coaching_effort_name,
    c("Interval 1 (Lap 8)", "Interval 2 (Lap 10)")
  )
})

run_test("laps between selected efforts form duration-weighted recoveries", {
  laps <- coaching_lap_fixture(
    c(1.3, 0.6, 0.5, 1.25),
    duration = c(240, 300, 600, 240),
    names = c("Lap 8", "Lap 9", "Lap 10", "Lap 11")
  ) |>
    mutate(average_power_watts = c(340, 100, 130, 335))
  selected <- laps[c(1, 4), ] |>
    prepare_coaching_effort_presentation()
  recoveries <- summarise_recovery_intervals(laps, selected)

  expect_equal(recoveries$recovery_name, "R1")
  expect_equal(recoveries$moving_time_seconds, 900)
  expect_equal(recoveries$average_power_watts, 120)
  expect_equal(recoveries$source_laps, "Lap 9, Lap 10")
})

run_test("optional report notes accept pipes or newlines", {
  expect_equal(
    split_report_notes("First note|Second note\nThird note"),
    c("First note", "Second note", "Third note")
  )
  expect_equal(split_report_notes(""), character())
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

run_test("coaching effort telemetry is normalised to the lap", {
  streams <- tibble(
    sample_index = 1:181,
    time_seconds = 0:180,
    distance_metres = 0:180,
    altitude_metres = 100,
    watts = 200,
    heartrate_bpm = 140,
    cadence_rpm = 85
  )
  effort <- coaching_lap_fixture(1.3, duration = 61) |>
    mutate(
      start_sample_index = 61L,
      end_sample_index = 121L,
      start_time_seconds = 60,
      end_time_seconds = 121,
      start_distance_metres = 60,
      end_distance_metres = 120
    )
  model <- build_coaching_effort_model(effort, streams)

  expect_equal(range(model$streams$effort_time_minutes), c(0, 1))
  expect_equal(range(model$streams$effort_distance_miles), c(0, 60 * 0.000621371))
})

run_test("coaching effort telemetry uses canonical time boundaries", {
  streams <- tibble(
    sample_index = 1:300,
    time_seconds = 0:299,
    distance_metres = 0:299,
    altitude_metres = 100 + (0:299) / 10,
    watts = c(rep(100, 100), rep(300, 60), rep(100, 140)),
    heartrate_bpm = 140,
    cadence_rpm = 85
  )
  effort <- coaching_lap_fixture(1.3, duration = 60) |>
    mutate(
      start_sample_index = 1L,
      end_sample_index = 60L,
      start_time_seconds = 100,
      end_time_seconds = 160
    )
  model <- build_coaching_effort_model(effort, streams)

  expect_equal(nrow(model$streams), 60L)
  expect_equal(mean(model$streams$watts), 300)
})

run_test("coaching effort elevation scale is local to the lap", {
  elevation <- tibble(
    effort_time_minutes = 0:4,
    altitude_metres = c(120, 125, 130, 140, 150)
  )
  plot <- plot_coaching_effort_metric(
    elevation,
    "altitude_metres",
    "Elevation",
    "Elevation (m)",
    report_colours$elevation,
    "#D7E3D2"
  )
  y_range <- ggplot2::ggplot_build(plot)$layout$panel_params[[1]]$y.range

  expect_true(y_range[[1]] > 100)
})

cat(sprintf("\n%d tests passed.\n", tests_run))
