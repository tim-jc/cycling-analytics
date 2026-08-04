get_ride_activity <- function(con, activity_id) {
  activity <- DBI::dbGetQuery(
    con,
    "SELECT activity_id, activity_name, sport_type, gear_id,
      start_datetime_local, start_date_local, distance_metres,
      moving_time_seconds, elapsed_time_seconds, elevation_gain_metres,
      average_speed_miles_per_hour, average_cadence_rpm,
      average_heartrate_bpm, average_power_watts,
      weighted_average_power_watts, energy_kilojoules, has_streams, has_laps
    FROM cycling_platform_silver.activities
    WHERE activity_id = ?",
    params = list(as.character(activity_id))
  )
  if (nrow(activity) != 1L) {
    stop("No trusted activity found for activity ID ", activity_id, call. = FALSE)
  }
  tibble::as_tibble(activity)
}

get_ride_streams <- function(con, activity_id) {
  DBI::dbGetQuery(
    con,
    "SELECT activity_id, sample_index, time_seconds, distance_metres,
      altitude_metres, velocity_smooth_metres_per_second, heartrate_bpm,
      cadence_rpm, watts, temperature_celsius, is_moving,
      grade_smooth_percent
    FROM cycling_platform_silver.activity_streams
    WHERE activity_id = ?
    ORDER BY sample_index",
    params = list(as.character(activity_id))
  ) |>
    tibble::as_tibble()
}

get_ride_best_efforts <- function(con, activity_id) {
  DBI::dbGetQuery(
    con,
    "SELECT activity_id, duration_seconds, peak_value, start_sample_index,
      end_sample_index, start_time_seconds, end_time_seconds,
      start_distance_metres, end_distance_metres, calculation_version
    FROM cycling_platform_gold.activity_best_efforts
    WHERE activity_id = ? AND metric_name = 'watts'
    ORDER BY duration_seconds",
    params = list(as.character(activity_id))
  ) |>
    tibble::as_tibble()
}

get_ride_laps <- function(con, activity_id) {
  DBI::dbGetQuery(
    con,
    "SELECT lap_id, activity_id, lap_index, lap_name,
      start_datetime_local, elapsed_time_seconds, moving_time_seconds,
      distance_metres, start_sample_index, end_sample_index,
      start_time_seconds, end_time_seconds,
      average_speed_metres_per_second, average_cadence_rpm,
      average_power_watts, average_heartrate_bpm,
      maximum_heartrate_bpm, elevation_gain_metres, is_device_watts
    FROM cycling_platform_silver.activity_laps
    WHERE activity_id = ?
    ORDER BY lap_index",
    params = list(as.character(activity_id))
  ) |>
    tibble::as_tibble()
}

load_ride_report_data <- function(con, activity_id) {
  list(
    activity = get_ride_activity(con, activity_id),
    streams = get_ride_streams(con, activity_id),
    best_efforts = get_ride_best_efforts(con, activity_id),
    laps = get_ride_laps(con, activity_id)
  )
}
