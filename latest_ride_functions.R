# Latest Ride presentation model -------------------------------------------

# Temporary dashboard selection policy. This is intentionally not a canonical
# activity classification. TODO: consume a reusable cycling-platform activity
# classification if coaching, MCP, or other consumers justify that product.
LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI <- 20
METRES_PER_MILE <- 1609.344

empty_latest_ride_activity <- function() {
  tibble::tibble(
    activity_id = character(),
    activity_name = character(),
    sport_type = character(),
    gear_id = character(),
    start_datetime_local = as.POSIXct(character()),
    start_date_local = as.Date(character()),
    distance_metres = double(),
    moving_time_seconds = double(),
    elapsed_time_seconds = double(),
    elevation_gain_metres = double(),
    average_speed_miles_per_hour = double(),
    average_cadence_rpm = double(),
    average_heartrate_bpm = double(),
    average_power_watts = double(),
    weighted_average_power_watts = double(),
    energy_kilojoules = double(),
    has_streams = logical(),
    has_laps = logical()
  )
}

empty_latest_ride_streams <- function() {
  tibble::tibble(
    activity_id = character(), sample_index = integer(), time_seconds = double(),
    distance_metres = double(), latitude = double(), longitude = double(),
    altitude_metres = double(), velocity_smooth_metres_per_second = double(),
    heartrate_bpm = double(), cadence_rpm = double(), watts = double(),
    temperature_celsius = double(), is_moving = logical()
  )
}

empty_latest_ride_efforts <- function() {
  tibble::tibble(
    activity_id = character(), duration_seconds = integer(), peak_value = double(),
    start_sample_index = integer(), end_sample_index = integer()
  )
}

select_latest_significant_activity <- function(
  activities,
  min_distance_mi = LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI
) {
  required <- c("activity_id", "sport_type", "start_datetime_local", "distance_metres")
  if (!all(required %in% names(activities))) {
    stop("Latest Ride selection requires: ", paste(required, collapse = ", "), call. = FALSE)
  }

  eligible <- activities |>
    dplyr::filter(
      .data$sport_type %in% c("Ride", "VirtualRide"),
      !is.na(.data$distance_metres),
      .data$distance_metres >= min_distance_mi * METRES_PER_MILE
    ) |>
    dplyr::arrange(dplyr::desc(.data$start_datetime_local), dplyr::desc(.data$activity_id))

  dplyr::slice_head(eligible, n = 1L)
}

get_latest_significant_ride <- function(
  con,
  min_distance_mi = LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI
) {
  result <- DBI::dbGetQuery(
    con,
    "SELECT activity_id, activity_name, sport_type, gear_id,
      start_datetime_local, start_date_local, distance_metres,
      moving_time_seconds, elapsed_time_seconds, elevation_gain_metres,
      average_speed_miles_per_hour, average_cadence_rpm,
      average_heartrate_bpm, average_power_watts,
      weighted_average_power_watts, energy_kilojoules, has_streams, has_laps
    FROM cycling_platform_silver.activities
    WHERE sport_type IN ('Ride', 'VirtualRide')
      AND distance_metres >= ?
    ORDER BY start_datetime_local DESC, activity_id DESC
    LIMIT 1",
    params = list(min_distance_mi * METRES_PER_MILE)
  ) |>
    tibble::as_tibble()

  if (nrow(result) == 0L) empty_latest_ride_activity() else result
}

get_latest_ride_streams <- function(con, activity_id) {
  if (length(activity_id) == 0L || is.na(activity_id[[1]])) {
    return(empty_latest_ride_streams())
  }

  DBI::dbGetQuery(
    con,
    "SELECT activity_id, sample_index, time_seconds, distance_metres,
      latitude, longitude, altitude_metres,
      velocity_smooth_metres_per_second, heartrate_bpm, cadence_rpm, watts,
      temperature_celsius, is_moving
    FROM cycling_platform_silver.activity_streams
    WHERE activity_id = ?
    ORDER BY sample_index",
    params = list(as.character(activity_id[[1]]))
  ) |>
    tibble::as_tibble()
}

get_latest_ride_best_efforts <- function(
  con,
  activity_id,
  durations_seconds = c(5L, 60L, 300L, 1200L, 3600L)
) {
  if (length(activity_id) == 0L || is.na(activity_id[[1]])) {
    return(empty_latest_ride_efforts())
  }

  placeholders <- paste(rep("?", length(durations_seconds)), collapse = ", ")
  DBI::dbGetQuery(
    con,
    paste0(
      "SELECT activity_id, duration_seconds, peak_value, start_sample_index, end_sample_index\n",
      "FROM cycling_platform_gold.activity_best_efforts\n",
      "WHERE activity_id = ? AND metric_name = 'watts'\n",
      "  AND duration_seconds IN (", placeholders, ")\n",
      "ORDER BY duration_seconds"
    ),
    params = c(list(as.character(activity_id[[1]])), as.list(as.integer(durations_seconds)))
  ) |>
    tibble::as_tibble()
}

latest_ride_stream_availability <- function(streams) {
  has_values <- function(column) column %in% names(streams) && any(!is.na(streams[[column]]))
  c(
    elevation = has_values("altitude_metres"),
    power = has_values("watts"),
    heart_rate = has_values("heartrate_bpm"),
    gps = has_values("latitude") && has_values("longitude")
  )
}

latest_ride_empty_message <- function(
  min_distance_mi = LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI
) {
  sprintf(
    "No qualifying ride found. Latest Ride currently includes the most recent cycling activity of at least %g miles.",
    min_distance_mi
  )
}

latest_ride_notice <- function(text) {
  htmltools::div(class = "latest-ride-notice", text)
}

format_latest_duration <- function(seconds) {
  if (length(seconds) == 0L || is.na(seconds)) return("Unavailable")
  sprintf("%d:%02d", floor(seconds / 3600), floor((seconds %% 3600) / 60))
}

format_latest_metric <- function(value, suffix, digits = 0L) {
  if (length(value) == 0L || is.na(value)) return("Unavailable")
  paste0(format(round(value, digits), nsmall = digits, trim = TRUE, big.mark = ","), suffix)
}

latest_ride_identity <- function(activity) {
  if (nrow(activity) == 0L) return(latest_ride_notice(latest_ride_empty_message()))
  ride <- activity[1, ]
  setting <- if (isTRUE(ride$sport_type == "VirtualRide")) "Indoor" else "Outdoor"
  link <- sprintf("https://www.strava.com/activities/%s", ride$activity_id)

  htmltools::div(
    class = "latest-ride-identity",
    htmltools::h3(ride$activity_name),
    htmltools::p(
      format(as.POSIXct(ride$start_datetime_local), "%A %d %B %Y, %H:%M"),
      htmltools::span(class = "latest-ride-dot", " • "), setting
    ),
    htmltools::p(
      htmltools::a("View source activity", href = link, target = "_blank"),
      htmltools::span(class = "latest-ride-rule", sprintf(
        "Temporary selection rule: latest cycling activity ≥ %g mi",
        LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI
      ))
    )
  )
}

latest_ride_value_box <- function(value, caption, icon = "fa-bicycle") {
  flexdashboard::valueBox(value, caption = caption, icon = icon, color = "#EDF0F1")
}

draw_latest_ride_trace <- function(streams, metric, label, units, colour) {
  available <- latest_ride_stream_availability(streams)
  key <- switch(metric, altitude_metres = "elevation", watts = "power", heartrate_bpm = "heart_rate")
  if (nrow(streams) == 0L || !isTRUE(available[[key]])) {
    return(latest_ride_notice(sprintf("%s telemetry is unavailable for this ride.", label)))
  }

  trace_data <- streams |>
    dplyr::filter(!is.na(.data[[metric]])) |>
    dplyr::mutate(distance_mi = .data$distance_metres / METRES_PER_MILE)

  plotly::plot_ly(
    trace_data,
    x = ~distance_mi,
    y = trace_data[[metric]],
    type = "scatter", mode = "lines",
    line = list(color = colour, width = 1.4),
    hovertemplate = paste0("%{x:.1f} mi<br>%{y:.0f} ", units, "<extra></extra>")
  ) |>
    plotly::layout(
      xaxis = list(title = "Distance (mi)"),
      yaxis = list(title = units, rangemode = "tozero"),
      margin = list(l = 48, r = 15, b = 42, t = 10),
      showlegend = FALSE
    )
}

draw_latest_ride_map <- function(streams, sport_type) {
  if (identical(sport_type, "VirtualRide")) {
    return(latest_ride_notice("Route map is not applicable to this indoor ride."))
  }
  if (!isTRUE(latest_ride_stream_availability(streams)[["gps"]])) {
    return(latest_ride_notice("GPS coordinates are unavailable for this ride."))
  }
  route <- streams |>
    dplyr::filter(!is.na(.data$latitude), !is.na(.data$longitude))

  leaflet::leaflet(route) |>
    leaflet::addProviderTiles(leaflet::providers$CartoDB.Positron) |>
    leaflet::addPolylines(
      lng = ~longitude, lat = ~latitude,
      color = "#17324D", weight = 4, opacity = 0.9
    ) |>
    leaflet::fitBounds(
      min(route$longitude), min(route$latitude),
      max(route$longitude), max(route$latitude)
    )
}

latest_ride_efforts_table <- function(efforts) {
  if (nrow(efforts) == 0L) {
    return(latest_ride_notice("No selected-duration Gold power efforts are available for this ride."))
  }
  labels <- c(`5` = "5 sec", `60` = "1 min", `300` = "5 min", `1200` = "20 min", `3600` = "60 min")
  display <- efforts |>
    dplyr::mutate(
      Duration = unname(labels[as.character(.data$duration_seconds)]),
      `Best power` = paste0(round(.data$peak_value), " W")
    ) |>
    dplyr::select(.data$Duration, .data$`Best power`)
  knitr::kable(display, align = c("l", "r"), row.names = FALSE)
}

latest_ride_observations <- function(activity, streams, efforts) {
  if (nrow(activity) == 0L) return(latest_ride_empty_message())
  availability <- latest_ride_stream_availability(streams)
  ride <- activity[1, ]
  facts <- c(
    sprintf("Recorded %.1f miles in %s moving time.", ride$distance_metres / METRES_PER_MILE, format_latest_duration(ride$moving_time_seconds)),
    if (!is.na(ride$elevation_gain_metres)) sprintf("Accumulated %s m of elevation gain.", format(round(ride$elevation_gain_metres), big.mark = ",")) else NULL,
    if (nrow(efforts) > 0L) sprintf("Strongest displayed Gold effort: %s W for %s.", round(max(efforts$peak_value, na.rm = TRUE)), format_latest_effort_duration(efforts$duration_seconds[which.max(efforts$peak_value)])) else NULL,
    if (any(!availability)) paste0("Unavailable telemetry: ", paste(names(availability)[!availability], collapse = ", "), ".") else NULL
  )
  htmltools::tags$ul(lapply(facts, htmltools::tags$li))
}

format_latest_effort_duration <- function(seconds) {
  if (seconds %% 3600 == 0) return(sprintf("%g hr", seconds / 3600))
  if (seconds %% 60 == 0) return(sprintf("%g min", seconds / 60))
  sprintf("%g sec", seconds)
}
