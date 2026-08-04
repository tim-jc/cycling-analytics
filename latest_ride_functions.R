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
    activity_id = character(),
    sample_index = integer(),
    time_seconds = double(),
    distance_metres = double(),
    latitude = double(),
    longitude = double(),
    altitude_metres = double(),
    velocity_smooth_metres_per_second = double(),
    heartrate_bpm = double(),
    cadence_rpm = double(),
    watts = double(),
    temperature_celsius = double(),
    is_moving = logical()
  )
}

empty_latest_ride_efforts <- function() {
  tibble::tibble(
    activity_id = character(),
    duration_seconds = integer(),
    peak_value = double(),
    start_sample_index = integer(),
    end_sample_index = integer()
  )
}

select_latest_significant_activity <- function(
  activities,
  min_distance_mi = LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI
) {
  required <- c(
    "activity_id",
    "sport_type",
    "start_datetime_local",
    "distance_metres"
  )
  if (!all(required %in% names(activities))) {
    stop(
      "Latest Ride selection requires: ",
      paste(required, collapse = ", "),
      call. = FALSE
    )
  }

  eligible <- activities |>
    dplyr::filter(
      .data$sport_type %in% c("Ride", "VirtualRide"),
      !is.na(.data$distance_metres),
      .data$distance_metres >= min_distance_mi * METRES_PER_MILE
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$start_datetime_local),
      dplyr::desc(.data$activity_id)
    )

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
  durations_seconds = NULL
) {
  if (length(activity_id) == 0L || is.na(activity_id[[1]])) {
    return(empty_latest_ride_efforts())
  }

  duration_filter <- ""
  params <- list(as.character(activity_id[[1]]))
  if (!is.null(durations_seconds)) {
    placeholders <- paste(rep("?", length(durations_seconds)), collapse = ", ")
    duration_filter <- paste0(" AND duration_seconds IN (", placeholders, ")")
    params <- c(params, as.list(as.integer(durations_seconds)))
  }
  DBI::dbGetQuery(
    con,
    paste0(
      "SELECT activity_id, duration_seconds, peak_value, start_sample_index, end_sample_index\n",
      "FROM cycling_platform_gold.activity_best_efforts\n",
      "WHERE activity_id = ? AND metric_name = 'watts'\n",
      duration_filter,
      "\n",
      "ORDER BY duration_seconds"
    ),
    params = params
  ) |>
    tibble::as_tibble()
}

get_latest_ride_rankings <- function(con, activity_id) {
  if (length(activity_id) == 0L || is.na(activity_id[[1]])) {
    return(tibble::tibble())
  }

  activity_ranks <- DBI::dbGetQuery(
    con,
    "SELECT
      1 + SUM(CASE WHEN peers.distance_metres > selected.distance_metres THEN 1 ELSE 0 END) AS achievement_rank,
      COUNT(*) AS comparison_count,
      'distance' AS ranking_type,
      0 AS duration_seconds,
      selected.distance_metres AS metric_value
    FROM cycling_platform_silver.activities selected
    INNER JOIN cycling_platform_silver.activities peers
      ON YEAR(peers.start_date_local) = YEAR(selected.start_date_local)
      AND peers.sport_type IN ('Ride', 'VirtualRide')
    WHERE selected.activity_id = ?
    UNION ALL
    SELECT
      1 + SUM(CASE WHEN peers.average_speed_miles_per_hour > selected.average_speed_miles_per_hour THEN 1 ELSE 0 END),
      COUNT(*), 'speed_50_miles', 0, selected.average_speed_miles_per_hour
    FROM cycling_platform_silver.activities selected
    INNER JOIN cycling_platform_silver.activities peers
      ON YEAR(peers.start_date_local) = YEAR(selected.start_date_local)
      AND peers.sport_type = 'Ride'
      AND peers.distance_metres >= 50 * ?
    WHERE selected.activity_id = ?
      AND selected.sport_type = 'Ride'
      AND selected.distance_metres >= 50 * ?",
    params = list(
      as.character(activity_id[[1]]),
      METRES_PER_MILE,
      as.character(activity_id[[1]]),
      METRES_PER_MILE
    )
  ) |>
    tibble::as_tibble()

  power_ranks <- DBI::dbGetQuery(
    con,
    "SELECT current.duration_seconds, current.peak_value AS metric_value,
      1 + SUM(CASE WHEN peers.peak_value > current.peak_value THEN 1 ELSE 0 END) AS achievement_rank,
      COUNT(peers.activity_id) AS comparison_count,
      'power' AS ranking_type
    FROM cycling_platform_gold.activity_best_efforts current
    INNER JOIN cycling_platform_silver.activities selected
      ON selected.activity_id = current.activity_id
    INNER JOIN cycling_platform_gold.activity_best_efforts peers
      ON peers.metric_name = 'watts'
      AND peers.duration_seconds = current.duration_seconds
      AND peers.is_record_eligible = 1
    INNER JOIN cycling_platform_silver.activities peer_activity
      ON peer_activity.activity_id = peers.activity_id
      AND YEAR(peer_activity.start_date_local) = YEAR(selected.start_date_local)
    WHERE current.activity_id = ?
      AND current.metric_name = 'watts'
      AND current.is_record_eligible = 1
    GROUP BY current.duration_seconds, current.peak_value",
    params = list(as.character(activity_id[[1]]))
  ) |>
    tibble::as_tibble()

  dplyr::bind_rows(activity_ranks, power_ranks)
}

latest_ride_stream_availability <- function(streams) {
  has_values <- function(column) {
    column %in% names(streams) && any(!is.na(streams[[column]]))
  }
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
  if (length(seconds) == 0L || is.na(seconds)) {
    return("Unavailable")
  }
  sprintf("%d:%02d", floor(seconds / 3600), floor((seconds %% 3600) / 60))
}

format_latest_metric <- function(value, suffix, digits = 0L) {
  if (length(value) == 0L || is.na(value)) {
    return("Unavailable")
  }
  paste0(
    format(round(value, digits), nsmall = digits, trim = TRUE, big.mark = ","),
    suffix
  )
}

latest_ride_identity <- function(activity) {
  if (nrow(activity) == 0L) {
    return(latest_ride_notice(latest_ride_empty_message()))
  }
  ride <- activity[1, ]
  link <- sprintf("https://www.strava.com/activities/%s", ride$activity_id)

  flexdashboard::valueBox(
    as.character(ride$activity_name),
    caption = format(
      as.POSIXct(ride$start_datetime_local),
      "%A %d %B %Y, %H:%M"
    ),
    icon = "fa-bicycle",
    color = "#EDF0F1",
    href = link
  )
}

latest_ride_value_box <- function(value, caption, icon = "fa-bicycle") {
  flexdashboard::valueBox(
    value,
    caption = caption,
    icon = icon,
    color = "#EDF0F1"
  )
}

draw_latest_ride_trace <- function(streams, metric, label, units, colour) {
  available <- latest_ride_stream_availability(streams)
  key <- switch(
    metric,
    altitude_metres = "elevation",
    watts = "power",
    heartrate_bpm = "heart_rate"
  )
  if (nrow(streams) == 0L || !isTRUE(available[[key]])) {
    return(latest_ride_notice(sprintf(
      "%s telemetry is unavailable for this ride.",
      label
    )))
  }

  trace_data <- streams |>
    dplyr::filter(!is.na(.data[[metric]])) |>
    dplyr::mutate(distance_mi = .data$distance_metres / METRES_PER_MILE)

  plotly::plot_ly(
    trace_data,
    x = ~distance_mi,
    y = trace_data[[metric]],
    type = "scatter",
    mode = "lines",
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
    return(latest_ride_notice(
      "Route map is not applicable to this indoor ride."
    ))
  }
  if (!isTRUE(latest_ride_stream_availability(streams)[["gps"]])) {
    return(latest_ride_notice("GPS coordinates are unavailable for this ride."))
  }
  route <- streams |>
    dplyr::filter(!is.na(.data$latitude), !is.na(.data$longitude))

  leaflet::leaflet(route) |>
    leaflet::addProviderTiles(leaflet::providers$CartoDB.Positron) |>
    leaflet::addPolylines(
      lng = ~longitude,
      lat = ~latitude,
      color = "#17324D",
      weight = 2,
      opacity = 0.9
    ) |>
    leaflet::fitBounds(
      min(route$longitude),
      min(route$latitude),
      max(route$longitude),
      max(route$latitude)
    )
}

draw_latest_ride_power_curve <- function(efforts) {
  efforts <- efforts |>
    dplyr::filter(
      !is.na(.data$duration_seconds),
      !is.na(.data$peak_value),
      .data$duration_seconds > 0
    )
  if (nrow(efforts) == 0L) {
    return(latest_ride_notice(
      "A ride-only Gold power curve is unavailable for this ride."
    ))
  }

  tick_values <- c(5, 60, 300, 1200, 3600)
  tick_labels <- c("5 s", "1 min", "5 min", "20 min", "60 min")
  plotly::plot_ly(
    efforts,
    x = ~duration_seconds,
    y = ~peak_value,
    type = "scatter",
    mode = "lines+markers",
    line = list(color = "#17324D", width = 3),
    marker = list(
      color = "#F2A46F",
      size = 6,
      line = list(color = "#17324D", width = 1)
    ),
    text = ~ paste0(
      format_latest_effort_duration(duration_seconds),
      ": ",
      round(peak_value),
      " W"
    ),
    hovertemplate = "%{text}<extra></extra>"
  ) |>
    plotly::layout(
      xaxis = list(
        type = "log",
        title = "Duration",
        tickvals = tick_values,
        ticktext = tick_labels
      ),
      yaxis = list(title = "Best power (W)", rangemode = "tozero"),
      margin = list(l = 55, r = 15, b = 45, t = 10),
      showlegend = FALSE
    )
}

get_latest_ride_hr_max <- function() {
  configured <- Sys.getenv("CYCLING_ANALYTICS_HR_MAX_BPM", "")
  value <- suppressWarnings(as.numeric(configured))
  if (!nzchar(configured) || is.na(value) || value <= 0) NA_real_ else value
}

build_latest_ride_hr_zones <- function(
  streams,
  max_hr_bpm = get_latest_ride_hr_max()
) {
  if (
    nrow(streams) == 0L ||
      !"heartrate_bpm" %in% names(streams) ||
      all(is.na(streams$heartrate_bpm)) ||
      is.na(max_hr_bpm)
  ) {
    return(tibble::tibble())
  }

  breaks <- c(0, .6, .7, .8, .9, Inf) * max_hr_bpm
  streams |>
    dplyr::filter(!is.na(.data$heartrate_bpm)) |>
    dplyr::mutate(
      zone = cut(
        .data$heartrate_bpm,
        breaks = breaks,
        labels = paste0("Z", 1:5),
        right = FALSE
      ),
      zone = factor(.data$zone, levels = paste0("Z", 1:5))
    ) |>
    dplyr::count(.data$zone, .drop = FALSE, name = "seconds") |>
    dplyr::mutate(minutes = .data$seconds / 60)
}

draw_latest_ride_hr_zones <- function(
  streams,
  max_hr_bpm = get_latest_ride_hr_max()
) {
  if (!isTRUE(latest_ride_stream_availability(streams)[["heart_rate"]])) {
    return(latest_ride_notice(
      "Heart-rate telemetry is unavailable for this ride."
    ))
  }
  if (is.na(max_hr_bpm)) {
    return(latest_ride_notice(
      "Set CYCLING_ANALYTICS_HR_MAX_BPM to display temporary presentation-only HR zones."
    ))
  }
  zones <- build_latest_ride_hr_zones(streams, max_hr_bpm)
  colours <- c("#DDE8EF", "#BCD4E3", "#88B2CC", "#F2C38F", "#D97852")
  plotly::plot_ly(
    zones,
    x = ~minutes,
    y = ~zone,
    type = "bar",
    orientation = "h",
    marker = list(color = colours, line = list(color = "#17324D", width = 1)),
    text = ~ paste0(round(minutes), " min"),
    textposition = "auto",
    hovertemplate = "%{y}: %{x:.1f} min<extra></extra>"
  ) |>
    plotly::layout(
      xaxis = list(title = "Time (minutes)"),
      yaxis = list(title = "", autorange = "reversed"),
      margin = list(l = 40, r = 15, b = 42, t = 10),
      showlegend = FALSE
    )
}

ordinal <- function(value) {
  vapply(
    as.integer(value),
    function(one_value) {
      suffix <- if (one_value %% 100 %in% 11:13) {
        "th"
      } else {
        c("th", "st", "nd", "rd", rep("th", 6))[one_value %% 10 + 1]
      }
      paste0(one_value, suffix)
    },
    character(1)
  )
}

latest_ride_highlights <- function(rankings) {
  if (nrow(rankings) == 0L) {
    return(latest_ride_notice(
      "No comparative highlights are available for this ride."
    ))
  }

  candidates <- rankings |>
    dplyr::filter(!is.na(.data$achievement_rank), .data$comparison_count > 0) |>
    dplyr::mutate(
      priority = dplyr::case_when(
        .data$ranking_type == "distance" ~ 1,
        .data$ranking_type == "speed_50_miles" ~ 2,
        .data$ranking_type == "power" ~ 3,
        TRUE ~ 9
      ),
      label = dplyr::case_when(
        .data$ranking_type == "distance" ~ paste0(
          ordinal(.data$achievement_rank),
          " longest ride this year"
        ),
        .data$ranking_type == "speed_50_miles" ~ paste0(
          ordinal(.data$achievement_rank),
          " fastest 50+ mile ride this year"
        ),
        .data$ranking_type == "power" ~ paste0(
          ordinal(.data$achievement_rank),
          " best ",
          vapply(
            .data$duration_seconds,
            format_latest_effort_duration,
            character(1)
          ),
          " power this year · ",
          round(.data$metric_value),
          " W"
        ),
        TRUE ~ NA_character_
      )
    ) |>
    dplyr::filter(!is.na(.data$label), .data$achievement_rank <= 10) |>
    dplyr::arrange(
      .data$priority,
      .data$achievement_rank,
      dplyr::desc(.data$duration_seconds)
    ) |>
    dplyr::slice_head(n = 4)

  if (nrow(candidates) == 0L) {
    return(latest_ride_notice("No top-ten yearly highlights for this ride."))
  }
  htmltools::div(
    class = "latest-ride-highlights",
    lapply(candidates$label, function(label) {
      htmltools::div(class = "latest-ride-highlight", label)
    })
  )
}

latest_ride_efforts_table <- function(efforts) {
  if (nrow(efforts) == 0L) {
    return(latest_ride_notice(
      "No selected-duration Gold power efforts are available for this ride."
    ))
  }
  labels <- c(
    `5` = "5 sec",
    `60` = "1 min",
    `300` = "5 min",
    `1200` = "20 min",
    `3600` = "60 min"
  )
  display <- efforts |>
    dplyr::mutate(
      Duration = unname(labels[as.character(.data$duration_seconds)]),
      `Best power` = paste0(round(.data$peak_value), " W")
    ) |>
    dplyr::select(.data$Duration, .data$`Best power`)
  knitr::kable(display, align = c("l", "r"), row.names = FALSE)
}

latest_ride_observations <- function(activity, streams, efforts) {
  if (nrow(activity) == 0L) {
    return(latest_ride_empty_message())
  }
  availability <- latest_ride_stream_availability(streams)
  ride <- activity[1, ]
  facts <- c(
    sprintf(
      "Recorded %.1f miles in %s moving time.",
      ride$distance_metres / METRES_PER_MILE,
      format_latest_duration(ride$moving_time_seconds)
    ),
    if (!is.na(ride$elevation_gain_metres)) {
      sprintf(
        "Accumulated %s m of elevation gain.",
        format(round(ride$elevation_gain_metres), big.mark = ",")
      )
    } else {
      NULL
    },
    if (nrow(efforts) > 0L) {
      sprintf(
        "Strongest displayed Gold effort: %s W for %s.",
        round(max(efforts$peak_value, na.rm = TRUE)),
        format_latest_effort_duration(efforts$duration_seconds[which.max(
          efforts$peak_value
        )])
      )
    } else {
      NULL
    },
    if (any(!availability)) {
      paste0(
        "Unavailable telemetry: ",
        paste(names(availability)[!availability], collapse = ", "),
        "."
      )
    } else {
      NULL
    }
  )
  htmltools::tags$ul(lapply(facts, htmltools::tags$li))
}

format_latest_effort_duration <- function(seconds) {
  vapply(
    as.numeric(seconds),
    function(one_duration) {
      if (one_duration %% 3600 == 0) {
        return(sprintf("%g hr", one_duration / 3600))
      }
      if (one_duration %% 60 == 0) {
        return(sprintf("%g min", one_duration / 60))
      }
      sprintf("%g sec", one_duration)
    },
    character(1)
  )
}
