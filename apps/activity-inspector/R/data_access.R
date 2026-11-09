validate_inspector_activity_id <- function(activity_id) {
  value <- trimws(as.character(activity_id))
  if (length(value) != 1L || is.na(value) || !nzchar(value) ||
      !grepl("^[0-9]+$", value)) {
    stop("Activity ID must contain digits only.", call. = FALSE)
  }
  value
}

fetch_inspector_activity <- function(
  connection,
  activity_id,
  get_query = DBI::dbGetQuery
) {
  activity_id <- validate_inspector_activity_id(activity_id)
  get_query(
    connection,
    paste(
      "SELECT activity_id, activity_name, sport_type, activity_type,",
      "timezone_name, start_datetime_utc, start_datetime_local,",
      "start_date_local, start_time_local, distance_metres,",
      "moving_time_seconds, elapsed_time_seconds, elevation_gain_metres,",
      "has_streams, transformed_at",
      "FROM cycling_platform_silver.activities",
      "WHERE activity_id = ?"
    ),
    params = list(activity_id)
  )
}

fetch_inspector_streams <- function(
  connection,
  activity_id,
  get_query = DBI::dbGetQuery
) {
  activity_id <- validate_inspector_activity_id(activity_id)
  get_query(
    connection,
    paste(
      "SELECT activity_id, sample_index, time_seconds, distance_metres,",
      "latitude, longitude, altitude_metres,",
      "velocity_smooth_metres_per_second, heartrate_bpm, cadence_rpm,",
      "watts, temperature_celsius, is_moving, grade_smooth_percent,",
      "raw_stream_count, raw_max_original_size, raw_stream_retrieved_at,",
      "transformed_at",
      "FROM cycling_platform_silver.activity_streams",
      "WHERE activity_id = ?",
      "ORDER BY sample_index"
    ),
    params = list(activity_id)
  )
}

load_inspector_activity <- function(
  activity_id,
  connection_factory = function() connect_db(max_attempts = 1L, wait_seconds = 0),
  disconnect = DBI::dbDisconnect,
  get_query = DBI::dbGetQuery
) {
  activity_id <- validate_inspector_activity_id(activity_id)
  connection <- connection_factory()
  on.exit(disconnect(connection), add = TRUE)

  activity <- fetch_inspector_activity(
    connection,
    activity_id,
    get_query = get_query
  )
  if (nrow(activity) == 0L) {
    return(list(activity = activity, streams = data.frame()))
  }

  streams <- fetch_inspector_streams(
    connection,
    activity_id,
    get_query = get_query
  )
  list(activity = activity, streams = streams)
}
