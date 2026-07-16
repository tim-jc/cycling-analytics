# Define values -----------------------------------------------------------

# Peaks units / conversions
peaks_units <- tibble::tribble(
  ~metric_name      , ~display_name , ~multiplier , ~units  ,
  "cadence_rpm"     , "cadence"     , 1           , "rpm"   ,
  "watts"           , "power"       , 1           , "W"     ,
  "heartrate_bpm"   , "heart rate"  , 1           , "bpm"   ,
  "velocity_smooth" , "speed"       , 2.23694     , "mph"   ,
  "distance"        , "distance"    , 0.000621371 , "miles"
)

# Functions

# Get streams
get_streams <- function(con) {
  DBI::dbGetQuery(
    conn = con,
    "SELECT
    a.activity_id,
    a.is_trainer,
    a.sport_type,
    a.start_date_local,
    a.distance_metres, 
    a.moving_time_seconds, 
    a.energy_kilojoules,
    s.latitude,
    s.longitude,
    s.sample_index AS stream_order
   FROM
    cycling_platform_silver.activities a
   INNER JOIN cycling_platform_silver.activity_streams s
    ON a.activity_id = s.activity_id
   WHERE
    a.sport_type IN ('Ride','VirtualRide')
    AND YEAR(a.start_date_local) >= (YEAR(NOW()) - 1)
   ORDER BY a.activity_id, s.sample_index"
  )
}

# tbr streams
get_tbr_streams <- function(con) {
  DBI::dbGetQuery(
    conn = con,
    "SELECT
      a.activity_id,
      a.is_trainer,
      a.sport_type,
      a.start_date_local,
      a.distance_metres, 
      a.moving_time_seconds, 
      s.latitude,
      s.longitude,
      s.sample_index AS stream_order
    FROM
      cycling_platform_silver.activities a
    INNER JOIN cycling_platform_silver.activity_streams s
      ON a.activity_id = s.activity_id
    WHERE
      a.activity_name like '%tbr%'
    ORDER BY a.activity_id, s.sample_index"
  )
}


# Assemble YTD stats
build_ytd_stats <- function(activity_streams) {
  test <- activity_streams |>
    select(
      activity_id,
      start_date_local,
      distance_metres,
      moving_time_seconds,
      energy_kilojoules,
    ) |>
    distinct() |>
    mutate(
      yr = year(start_date_local),
      yr_day = yday(start_date_local),
      distance_mi = distance_metres * 0.000621371,
      is_ton = distance_mi >= 100,
      moving_time_hr = moving_time_seconds / 3600
    ) |>
    group_by(yr) |>
    arrange(start_date_local) |>
    mutate(
      ytd_distance_mi = cumsum(distance_mi),
      ytd_tons = cumsum(is_ton),
      ytd_time_hr = cumsum(moving_time_hr),
      ytd_energy_kcal = cumsum(replace_na(energy_kilojoules, 0)),
      ytd_longest_ride = max(
        distance_mi[yr_day <= yday(Sys.Date())],
        na.rm = T
      ),
      yr_longest_ride = max(distance_mi, na.rm = T)
    ) |>
    select(
      activity_id,
      distance_mi,
      start_date_local,
      is_ton,
      matches("^yr|^ytd")
    ) |>
    mutate(start_date_local = as.Date(start_date_local)) |>
    group_by(start_date_local, yr, yr_day) |>
    summarise(
      ytd_distance_mi = max(ytd_distance_mi),
      ytd_predicted_distance_mi = (ytd_distance_mi / yday(Sys.Date())) * 365,
      ytd_tons = max(ytd_tons),
      is_ton_day = any(is_ton),
      ytd_time_hr = max(ytd_time_hr),
      ytd_energy_kcal = max(ytd_energy_kcal),
      ytd_longest_ride = max(ytd_longest_ride, na.rm = T),
      yr_longest_ride = max(yr_longest_ride, na.rm = T),
      is_activity_day = TRUE,
      activity_id = activity_id[distance_mi == max(distance_mi)],
      .groups = "drop"
    ) |>
    group_by(yr) |>
    mutate(
      yr_distance_mi = max(ytd_distance_mi),
      yr_tons = max(ytd_tons),
      yr_time_hr = max(ytd_time_hr),
      yr_energy_kcal = max(ytd_energy_kcal)
    ) |>
    right_join(tibble(
      start_date_local = seq.Date(
        floor_date(floor_date(Sys.Date(), "month") - years(1), "year"),
        ceiling_date(Sys.Date(), "year") - days(1),
        "days"
      )
    )) |>
    mutate(
      yr = year(start_date_local),
      yr_day = yday(start_date_local),
      is_activity_day = if_else(is.na(is_activity_day), F, is_activity_day),
      is_ton_day = if_else(is.na(is_ton_day), F, is_ton_day)
    ) |>
    arrange(yr, yr_day) |>
    filter(!(yr == year(Sys.Date()) & yr_day > yday(Sys.Date()))) |>
    fill(-activity_id, .direction = "down") |>
    mutate(
      across(where(is.numeric), ~ replace_na(.x, 0)),
      across(where(is.logical), ~ replace_na(.x, FALSE))
    ) |> # in case no riding on first day of year.
    mutate(
      ytd_val = yr_day == yday(Sys.Date()),
      yr_lbl = if_else(yr == year(Sys.Date()), "ytd", "pytd")
    ) |>
    ungroup()
}

get_position_extremities <- function(ytd_streams) {
  ytd_streams <- ytd_streams |> filter(sport_type == "Ride")

  # Manage the edge case early in the year when no outside rides logged yet
  if (nrow(ytd_streams) > 0) {
    position_extremities <- ytd_streams |>
      mutate(
        extremity = case_when(
          latitude == max(latitude, na.rm = T) ~ "N",
          latitude == min(latitude, na.rm = T) ~ "S",
          longitude == max(longitude, na.rm = T) ~ "E",
          longitude == min(longitude, na.rm = T) ~ "W"
        )
      ) |>
      filter(!is.na(extremity)) |>
      tidygeocoder::reverse_geocode(
        long = longitude,
        lat = latitude,
        full_results = T
      ) |>
      bind_rows(tibble(
        hamlet = NA_character_,
        village = NA_character_, # ensure the village and suburb columns are present
        town = NA_character_,
        suburb = NA_character_,
        neighbourhood = NA_character_,
        city = NA_character_
      ))
  } else {
    position_extremities <- tibble(extremity = c("N", "S", "E", "W")) |>
      mutate(
        latitude = NA,
        longitude = NA,
        hamlet = NA_character_,
        village = "No outside rides YTD",
        town = NA_character_,
        suburb = "No outside rides YTD",
        neighbourhood = NA_character_,
        city = NA_character_
      )
  }
  return(position_extremities)
}


get_ytd_values <- function(metric_to_display, ytd_stats) {
  ytd_stats |>
    filter(ytd_val) |>
    select(yr_lbl, matches("^ytd"), matches(metric_to_display), -ytd_val) |>
    pivot_longer(-yr_lbl, names_to = "metric") |>
    filter(str_detect(metric, metric_to_display)) |>
    mutate(
      value = round(value, 1),
      yr_lbl = if_else(
        str_detect(metric, "^yr_"),
        str_replace(yr_lbl, "td", "r"),
        yr_lbl
      )
    ) |>
    select(-metric) |>
    deframe()
}

get_ytd_valuebox <- function(
  metric_to_display,
  ytd_stats
) {
  vals <- get_ytd_values(
    metric_to_display,
    ytd_stats
  )

  icon_str <- case_when(
    vals["ytd"] > vals["pytd"] ~ "fa-arrow-up",
    vals["ytd"] < vals["pytd"] ~ "fa-arrow-down",
    vals["ytd"] == vals["pytd"] ~ "fa-arrows-left-right"
  )

  valueBox(
    vals["ytd"],
    icon = icon_str,
    color = "#EDF0F1"
  )
}

build_activity_summary <- function(activity_streams) {
  activity_streams |>
    select(
      activity_id,
      sport_type,
      start_date_local,
      distance_metres,
      moving_time_seconds,
      energy_kilojoules
    ) |>
    distinct() |>
    mutate(
      start_date_local = as.Date(start_date_local),
      distance_mi = distance_metres * 0.000621371,
      moving_time_hr = moving_time_seconds / 3600
    )
}

get_annual_distance_goal_mi <- function(ytd_stats = NULL) {
  goal_env <- Sys.getenv("ANNUAL_DISTANCE_GOAL_MI", "")
  annual_goal_mi <- if (nzchar(goal_env)) {
    suppressWarnings(as.numeric(goal_env))
  } else {
    NA_real_
  }

  if (!is.na(annual_goal_mi) && annual_goal_mi > 0) {
    return(annual_goal_mi)
  }

  if (!is.null(ytd_stats)) {
    last_year_total_mi <- ytd_stats |>
      filter(yr_lbl == "pytd", ytd_val) |>
      summarise(distance_mi = max(yr_distance_mi, na.rm = TRUE)) |>
      pull(distance_mi)

    if (!is.na(last_year_total_mi) && last_year_total_mi > 0) {
      return(last_year_total_mi)
    }
  }

  NA_real_
}

get_annual_distance_goal_label <- function(ytd_stats) {
  annual_goal_mi <- get_annual_distance_goal_mi(ytd_stats)

  if (is.na(annual_goal_mi)) {
    return("no target")
  }

  str_glue("{round(annual_goal_mi, 0)} mi target")
}

get_latest_ride_valuebox <- function(activity_summary) {
  latest_ride <- activity_summary |>
    filter(sport_type == "Ride") |>
    arrange(desc(start_date_local)) |>
    slice_head(n = 1)

  if (nrow(latest_ride) == 0) {
    return(valueBox("No rides", icon = "fa-road", color = "#EDF0F1"))
  }

  valueBox(
    str_glue("{round(latest_ride$distance_mi, 1)} mi"),
    icon = "fa-road",
    color = "#EDF0F1",
    href = str_glue(
      "https://www.strava.com/activities/{latest_ride$activity_id}"
    )
  )
}

get_goal_progress_valuebox <- function(ytd_stats) {
  annual_goal_mi <- get_annual_distance_goal_mi(ytd_stats)

  if (is.na(annual_goal_mi)) {
    return(valueBox("No goal", icon = "fa-bullseye", color = "#EDF0F1"))
  }

  ytd_distance_mi <- get_ytd_values("distance_mi", ytd_stats)[["ytd"]]
  goal_progress <- ytd_distance_mi / annual_goal_mi

  valueBox(
    str_glue("{round(goal_progress * 100, 1)}%"),
    icon = "fa-bullseye",
    color = "#EDF0F1"
  )
}

get_goal_pace_valuebox <- function(ytd_stats) {
  annual_goal_mi <- get_annual_distance_goal_mi(ytd_stats)

  if (is.na(annual_goal_mi)) {
    return(valueBox(
      "No goal",
      icon = "fa-arrows-left-right",
      color = "#EDF0F1"
    ))
  }

  ytd_distance_mi <- get_ytd_values("distance_mi", ytd_stats)[["ytd"]]
  expected_distance_mi <- annual_goal_mi * (yday(Sys.Date()) / 365)
  pace_delta_mi <- ytd_distance_mi - expected_distance_mi

  icon_str <- case_when(
    pace_delta_mi > 0 ~ "fa-arrow-up",
    pace_delta_mi < 0 ~ "fa-arrow-down",
    TRUE ~ "fa-arrows-left-right"
  )

  valueBox(
    str_glue(
      "{round(abs(pace_delta_mi), 0)} mi {if_else(pace_delta_mi >= 0, 'ahead', 'behind')}"
    ),
    icon = icon_str,
    color = "#EDF0F1"
  )
}

get_ride_mix_valuebox <- function(activity_summary) {
  split_tbl <- activity_summary |>
    filter(year(start_date_local) == year(Sys.Date())) |>
    mutate(
      ride_type = if_else(sport_type == "VirtualRide", "indoor", "outdoor")
    ) |>
    group_by(ride_type) |>
    summarise(distance_mi = sum(distance_mi), .groups = "drop")

  if (nrow(split_tbl) == 0 || sum(split_tbl$distance_mi) == 0) {
    return(valueBox("No rides", icon = "fa-bicycle", color = "#EDF0F1"))
  }

  outdoor_mi <- split_tbl |>
    filter(ride_type == "outdoor") |>
    pull(distance_mi) |>
    sum()

  indoor_mi <- split_tbl |>
    filter(ride_type == "indoor") |>
    pull(distance_mi) |>
    sum()

  valueBox(
    str_glue("{round(outdoor_mi, 0)} / {round(indoor_mi, 0)} mi"),
    icon = "fa-bicycle",
    color = "#EDF0F1"
  )
}

format_effort_duration <- function(duration_seconds) {
  case_when(
    duration_seconds %% 60 == 0 ~ str_glue("{duration_seconds / 60} min"),
    TRUE ~ str_glue("{duration_seconds} sec")
  )
}

rolling_mean_trailing <- function(values, window = 10) {
  observed_values <- if_else(is.na(values), 0, values)
  observed_counts <- if_else(is.na(values), 0L, 1L)
  rolling_sums <- cumsum(observed_values)
  rolling_counts <- cumsum(observed_counts)
  lagged_sums <- lag(rolling_sums, window, default = 0)
  lagged_counts <- lag(rolling_counts, window, default = 0)
  window_sums <- rolling_sums - lagged_sums
  window_counts <- rolling_counts - lagged_counts

  if_else(window_counts > 0, window_sums / window_counts, NA_real_)
}

get_ytd_best_power_efforts <- function(
  con,
  durations_seconds = c(600, 1200, 1800, 3600)
) {
  durations_seconds <- as.integer(durations_seconds)
  durations_sql <- str_flatten_comma(durations_seconds)

  efforts <- DBI::dbGetQuery(
    conn = con,
    str_glue(
      "SELECT
        abe.activity_id,
        a.start_date_local,
        a.sport_type,
        abe.duration_seconds,
        abe.metric_name,
        abe.peak_value,
        abe.start_sample_index,
        abe.end_sample_index,
        abe.start_latitude,
        abe.start_longitude,
        abe.end_latitude,
        abe.end_longitude
      FROM cycling_platform_gold.activity_best_efforts abe
      INNER JOIN cycling_platform_silver.activities a
        ON abe.activity_id = a.activity_id
      WHERE abe.metric_name = 'watts'
        AND abe.duration_seconds IN ({durations_sql})
        AND YEAR(a.start_date_local) = YEAR(NOW())"
    )
  )

  efforts |>
    group_by(metric_name, duration_seconds) |>
    slice_max(peak_value, n = 1, with_ties = FALSE) |>
    ungroup() |>
    mutate(
      duration_label = format_effort_duration(duration_seconds),
      metric_label = "Power",
      peak_label = str_glue("{round(peak_value, 0)} W"),
      activity_url = str_glue("https://www.strava.com/activities/{activity_id}")
    ) |>
    arrange(duration_seconds)
}

get_best_effort_streams <- function(con, best_efforts) {
  if (nrow(best_efforts) == 0) {
    return(tibble())
  }

  activity_ids <- best_efforts |>
    pull(activity_id) |>
    unique()

  if (length(activity_ids) == 0) {
    return(tibble())
  }

  activity_ids_sql <- activity_ids |>
    as.numeric() |>
    format(scientific = FALSE, trim = TRUE) |>
    str_flatten_comma()

  streams <- DBI::dbGetQuery(
    conn = con,
    str_glue(
      "SELECT
        activity_id,
        sample_index AS stream_order,
        distance_metres,
        latitude,
        longitude,
        altitude_metres,
        watts
      FROM cycling_platform_silver.activity_streams
      WHERE activity_id IN ({activity_ids_sql})
      ORDER BY activity_id, sample_index"
    )
  )

  best_efforts |>
    inner_join(streams, by = "activity_id", relationship = "many-to-many") |>
    filter(
      stream_order >= start_sample_index,
      stream_order <= end_sample_index
    )
}

prepare_best_effort_stream <- function(
  best_effort_streams,
  best_efforts,
  duration_seconds
) {
  target_duration <- duration_seconds

  effort <- best_efforts |>
    filter(.data$duration_seconds == target_duration) |>
    slice_head(n = 1)

  if (nrow(effort) == 0 || nrow(best_effort_streams) == 0) {
    return(tibble())
  }

  effort_streams <- best_effort_streams |>
    filter(.data$duration_seconds == target_duration) |>
    arrange(stream_order)

  if (nrow(effort_streams) == 0) {
    return(tibble())
  }

  distance_start <- if (all(is.na(effort_streams$distance_metres))) {
    NA_real_
  } else {
    min(effort_streams$distance_metres, na.rm = TRUE)
  }

  effort_streams |>
    mutate(
      effort_distance_mi = (distance_metres - distance_start) *
        0.000621371,
      power_smooth = rolling_mean_trailing(watts, window = 10)
    )
}

get_gradient_fill_colour <- function(gradient_percent) {
  case_when(
    is.na(gradient_percent) ~ "rgba(148, 163, 184, 0.35)",
    gradient_percent < 0 ~ "rgba(96, 165, 250, 0.35)",
    gradient_percent < 3 ~ "rgba(34, 197, 94, 0.32)",
    gradient_percent < 6 ~ "rgba(250, 204, 21, 0.38)",
    gradient_percent < 9 ~ "rgba(249, 115, 22, 0.40)",
    TRUE ~ "rgba(239, 68, 68, 0.42)"
  )
}

build_elevation_gradient_blocks <- function(
  elevation_streams,
  block_metres = 1000,
  min_block_metres = 200
) {
  if (nrow(elevation_streams) < 2) {
    return(tibble())
  }

  elevation_streams |>
    filter(!is.na(distance_metres), !is.na(altitude_metres)) |>
    arrange(stream_order) |>
    mutate(
      distance_from_start_metres = distance_metres - min(distance_metres),
      gradient_block = floor(distance_from_start_metres / block_metres)
    ) |>
    group_by(gradient_block) |>
    summarise(
      block_start_mi = first(effort_distance_mi),
      block_end_mi = last(effort_distance_mi),
      block_distance_metres = last(distance_metres) - first(distance_metres),
      altitude_start_metres = first(altitude_metres),
      altitude_end_metres = last(altitude_metres),
      gradient_percent = if_else(
        block_distance_metres > 0,
        100 *
          (altitude_end_metres - altitude_start_metres) /
          block_distance_metres,
        NA_real_
      ),
      .groups = "drop"
    ) |>
    filter(block_distance_metres >= min_block_metres) |>
    mutate(
      fill_colour = get_gradient_fill_colour(gradient_percent),
      hover_lbl = str_glue(
        "{round(block_start_mi, 2)}-{round(block_end_mi, 2)} mi<br>{round(gradient_percent, 1)}%"
      )
    )
}

add_elevation_gradient_fills <- function(elevation_plot, elevation_streams) {
  gradient_blocks <- build_elevation_gradient_blocks(elevation_streams)

  if (nrow(gradient_blocks) == 0) {
    return(elevation_plot)
  }

  for (block_index in seq_len(nrow(gradient_blocks))) {
    block <- gradient_blocks[block_index, ]

    block_stream <- elevation_streams |>
      filter(
        effort_distance_mi >= block$block_start_mi,
        effort_distance_mi <= block$block_end_mi
      ) |>
      arrange(effort_distance_mi)

    if (nrow(block_stream) < 2) {
      next
    }

    polygon_tbl <- bind_rows(
      tibble(
        effort_distance_mi = first(block_stream$effort_distance_mi),
        altitude_metres = 0,
        hover_lbl = block$hover_lbl
      ),
      block_stream |>
        transmute(
          effort_distance_mi,
          altitude_metres,
          hover_lbl = block$hover_lbl
        ),
      tibble(
        effort_distance_mi = last(block_stream$effort_distance_mi),
        altitude_metres = 0,
        hover_lbl = block$hover_lbl
      )
    )

    elevation_plot <- elevation_plot |>
      plotly::add_trace(
        data = polygon_tbl,
        x = ~effort_distance_mi,
        y = ~altitude_metres,
        type = "scatter",
        mode = "lines",
        fill = "toself",
        fillcolor = block$fill_colour,
        line = list(color = "rgba(0,0,0,0)", width = 0),
        text = ~hover_lbl,
        hoverinfo = "text",
        showlegend = FALSE
      )
  }

  elevation_plot
}

get_best_effort_valuebox <- function(best_efforts, duration_seconds) {
  target_duration <- duration_seconds

  effort <- best_efforts |>
    filter(.data$duration_seconds == target_duration) |>
    slice_head(n = 1)

  if (nrow(effort) == 0) {
    return(valueBox(
      "No effort",
      caption = str_glue("{format_effort_duration(duration_seconds)} power"),
      icon = "fa-bolt",
      color = "#EDF0F1"
    ))
  }

  valueBox(
    effort$peak_label,
    caption = str_glue("{effort$duration_label} power"),
    icon = "fa-bolt",
    color = "#EDF0F1",
    href = effort$activity_url
  )
}

draw_best_effort_telemetry <- function(
  best_effort_streams,
  best_efforts,
  duration_seconds
) {
  target_duration <- duration_seconds

  effort <- best_efforts |>
    filter(.data$duration_seconds == target_duration) |>
    slice_head(n = 1)

  duration_label <- format_effort_duration(duration_seconds)

  if (nrow(effort) == 0) {
    return(draw_best_effort_placeholder(
      str_glue("No {duration_label} effort yet"),
      "No matching YTD power effort was found."
    ))
  }

  effort_streams <- prepare_best_effort_stream(
    best_effort_streams,
    best_efforts,
    duration_seconds
  ) |>
    filter(!is.na(effort_distance_mi))

  power_streams <- effort_streams |>
    filter(!is.na(power_smooth))

  if (nrow(power_streams) < 2) {
    return(draw_best_effort_placeholder(
      "No power trace",
      str_glue(
        "{effort$peak_label} on {format(as.Date(effort$start_date_local), '%d %b')}"
      )
    ))
  }

  power_plot <- plotly::plot_ly(
    power_streams,
    x = ~effort_distance_mi,
    y = ~power_smooth,
    type = "scatter",
    mode = "lines",
    text = ~ str_glue(
      "{round(effort_distance_mi, 2)} mi<br>{round(power_smooth, 0)} W"
    ),
    hoverinfo = "text",
    line = list(color = "#0C2340", width = 2)
  )

  elevation_streams <- effort_streams |>
    filter(!is.na(altitude_metres))

  if (effort$sport_type != "VirtualRide" && nrow(elevation_streams) >= 2) {
    elevation_plot <- plotly::plot_ly() |>
      add_elevation_gradient_fills(elevation_streams) |>
      plotly::add_trace(
        data = elevation_streams,
        x = ~effort_distance_mi,
        y = ~altitude_metres,
        type = "scatter",
        mode = "lines",
        text = ~ str_glue(
          "{round(effort_distance_mi, 2)} mi<br>{round(altitude_metres, 0)} m"
        ),
        hoverinfo = "text",
        line = list(color = "#0C2340", width = 2),
        showlegend = FALSE
      )
    elevation_annotation <- list()
  } else {
    elevation_plot <- plotly::plot_ly(
      power_streams,
      x = ~effort_distance_mi,
      y = rep(0, nrow(power_streams)),
      type = "scatter",
      mode = "lines",
      hoverinfo = "skip",
      line = list(color = "rgba(0,0,0,0)")
    )
    elevation_annotation <- list(
      list(
        text = "No outdoor elevation profile",
        x = 0.5,
        y = 0.22,
        xref = "paper",
        yref = "paper",
        showarrow = FALSE,
        font = list(color = "#334155", size = 12)
      )
    )
  }

  plotly::subplot(
    power_plot,
    elevation_plot,
    nrows = 2,
    shareX = TRUE,
    titleX = TRUE,
    titleY = TRUE,
    margin = 0.03,
    heights = c(0.5, 0.5)
  ) |>
    plotly::layout(
      showlegend = FALSE,
      margin = list(l = 50, r = 15, t = 10, b = 45),
      annotations = elevation_annotation,
      xaxis = list(
        title = "",
        showline = FALSE,
        zeroline = FALSE
      ),
      xaxis2 = list(
        title = "Miles",
        showline = FALSE,
        zeroline = FALSE
      ),
      yaxis = list(
        title = "Power /W",
        showline = FALSE,
        zeroline = FALSE
      ),
      yaxis2 = list(
        title = "Elevation /m",
        rangemode = "tozero",
        showline = FALSE,
        zeroline = FALSE,
        showticklabels = nrow(elevation_streams) >= 2 &&
          effort$sport_type != "VirtualRide"
      )
    )
}

draw_best_effort_placeholder <- function(title, detail, min_height = "320px") {
  htmltools::div(
    style = paste(
      str_glue("min-height: {min_height};"),
      "display: flex;",
      "flex-direction: column;",
      "align-items: center;",
      "justify-content: center;",
      "border: 1px solid #e5e7eb;",
      "background: #f8fafc;",
      "color: #334155;",
      "text-align: center;",
      "padding: 1rem;"
    ),
    htmltools::div(
      style = "font-size: 1.1rem; font-weight: 600; margin-bottom: 0.35rem;",
      title
    ),
    htmltools::div(
      style = "font-size: 0.9rem;",
      detail
    )
  )
}

draw_best_effort_detail <- function(
  best_effort_streams,
  best_efforts,
  duration_seconds
) {
  htmltools::tagList(
    htmltools::div(
      style = "height: 50%; min-height: 300px;",
      draw_best_effort_map(best_effort_streams, best_efforts, duration_seconds)
    ),
    htmltools::div(
      style = "height: 50%; min-height: 300px; margin-top: 0.5rem;",
      draw_best_effort_telemetry(
        best_effort_streams,
        best_efforts,
        duration_seconds
      )
    )
  )
}

draw_best_effort_map <- function(
  best_effort_streams,
  best_efforts,
  duration_seconds
) {
  target_duration <- duration_seconds

  effort <- best_efforts |>
    filter(.data$duration_seconds == target_duration) |>
    slice_head(n = 1)

  duration_label <- format_effort_duration(duration_seconds)

  if (nrow(effort) == 0) {
    return(draw_best_effort_placeholder(
      str_glue("No {duration_label} effort yet"),
      "No matching YTD power effort was found."
    ))
  }

  if (effort$sport_type == "VirtualRide") {
    return(draw_best_effort_placeholder(
      "Virtual ride",
      str_glue(
        "{effort$peak_label} on {format(as.Date(effort$start_date_local), '%d %b')}"
      )
    ))
  }

  if (nrow(best_effort_streams) == 0) {
    return(draw_best_effort_placeholder(
      "No GPS trace",
      str_glue(
        "{effort$peak_label} on {format(as.Date(effort$start_date_local), '%d %b')}"
      )
    ))
  }

  effort_streams <- best_effort_streams |>
    filter(.data$duration_seconds == target_duration) |>
    filter(!is.na(latitude), !is.na(longitude)) |>
    arrange(stream_order)

  if (nrow(effort_streams) < 2) {
    return(draw_best_effort_placeholder(
      "No GPS trace",
      str_glue(
        "{effort$peak_label} on {format(as.Date(effort$start_date_local), '%d %b')}"
      )
    ))
  }

  start_point <- slice_head(effort_streams, n = 1)
  end_point <- slice_tail(effort_streams, n = 1)
  lat_range <- range(effort_streams$latitude, na.rm = TRUE)
  lng_range <- range(effort_streams$longitude, na.rm = TRUE)

  leaflet() |>
    addTiles(
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_labels_under/{z}/{x}/{y}.png',
      attribution = paste(
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors',
        '&copy; <a href="https://cartodb.com/attributions">CartoDB</a>'
      )
    ) |>
    addPolylines(
      data = effort_streams,
      lat = ~latitude,
      lng = ~longitude,
      opacity = 0.75,
      weight = 4,
      color = "#0C2340"
    ) |>
    addCircleMarkers(
      data = start_point,
      lat = ~latitude,
      lng = ~longitude,
      radius = 5,
      stroke = TRUE,
      weight = 2,
      color = "#18BC9C",
      fillColor = "#18BC9C",
      fillOpacity = 0.9,
      popup = "Start"
    ) |>
    addCircleMarkers(
      data = end_point,
      lat = ~latitude,
      lng = ~longitude,
      radius = 5,
      stroke = TRUE,
      weight = 2,
      color = "#E74C3C",
      fillColor = "#E74C3C",
      fillOpacity = 0.9,
      popup = "End"
    ) |>
    fitBounds(
      lng1 = lng_range[[1]],
      lat1 = lat_range[[1]],
      lng2 = lng_range[[2]],
      lat2 = lat_range[[2]]
    )
}

draw_rolling_activity_curve <- function(activity_summary, window_days = 28) {
  rolling_tbl <- activity_summary |>
    filter(start_date_local >= Sys.Date() - days(120 + window_days)) |>
    group_by(start_date_local) |>
    summarise(
      distance_mi = sum(distance_mi),
      moving_time_hr = sum(moving_time_hr),
      .groups = "drop"
    ) |>
    right_join(
      tibble(
        start_date_local = seq.Date(Sys.Date() - days(120), Sys.Date(), "days")
      ),
      by = "start_date_local"
    ) |>
    arrange(start_date_local) |>
    mutate(
      across(c(distance_mi, moving_time_hr), ~ replace_na(.x, 0)),
      cumulative_distance_mi = cumsum(distance_mi),
      rolling_distance_mi = cumulative_distance_mi -
        lag(cumulative_distance_mi, n = window_days, default = 0),
      in_plot_window = start_date_local >= Sys.Date() - days(120),
      hover_lbl = str_glue(
        "{start_date_local}
{window_days}d distance = {round(rolling_distance_mi, 1)} mi"
      )
    ) |>
    filter(in_plot_window)

  plotly::plot_ly(
    rolling_tbl,
    x = ~start_date_local,
    y = ~rolling_distance_mi,
    type = "scatter",
    mode = "lines",
    fill = "tozeroy",
    text = ~hover_lbl,
    hoverinfo = "text",
    line = list(color = "#0C2340"),
    fillcolor = "rgba(12, 35, 64, 0.2)"
  ) |>
    plotly::layout(
      xaxis = list(title = ""),
      yaxis = list(title = str_glue("{window_days}d miles"))
    )
}

draw_activity_calendar <- function(activity_summary) {
  calendar_tbl <- activity_summary |>
    filter(year(start_date_local) == year(Sys.Date())) |>
    group_by(start_date_local) |>
    summarise(distance_mi = sum(distance_mi), .groups = "drop") |>
    right_join(
      tibble(
        start_date_local = seq.Date(
          floor_date(Sys.Date(), "year"),
          Sys.Date(),
          "days"
        )
      ),
      by = "start_date_local"
    ) |>
    mutate(
      distance_mi = replace_na(distance_mi, 0),
      week = isoweek(start_date_local),
      weekday = wday(start_date_local, label = TRUE, week_start = 1),
      hover_lbl = str_glue(
        "{start_date_local}
{round(distance_mi, 1)} mi"
      )
    )

  calendar_plot <- calendar_tbl |>
    ggplot(aes(x = week, y = weekday, fill = distance_mi, text = hover_lbl)) +
    geom_tile(color = "white", linewidth = 0.2) +
    scale_fill_gradient(low = "grey95", high = "#0C2340") +
    scale_y_discrete(limits = rev) +
    theme_minimal() +
    theme(legend.position = "none") +
    labs(x = "ISO week number", y = "")

  plotly::ggplotly(calendar_plot, tooltip = "text")
}

draw_ytd_curve <- function(metric_to_plot, ytd_stats) {
  ytd_tbl <- ytd_stats |>
    pivot_longer(c(matches("^ytd"), -ytd_val)) |>
    filter(name == metric_to_plot) |>
    mutate(
      hover_lbl = str_glue(
        "{start_date_local}
                                 N = {round(value, 1)}"
      ),
      activity_url = str_glue("https://www.strava.com/activities/{activity_id}")
    )

  ytd_curve <- ytd_tbl |>
    ggplot(aes(x = yr_day, y = value, colour = yr_lbl)) +
    geom_step(alpha = 0.5) +
    theme_minimal() +
    scale_colour_manual(values = c("pytd" = "grey85", "ytd" = "#0C2340")) +
    theme(legend.position = "none", axis.text.x = element_blank()) +
    labs(x = "", y = "")

  if (metric_to_plot == "ytd_tons") {
    ytd_curve <- ytd_curve +
      geom_point(
        data = ytd_tbl |> filter(is_ton_day),
        aes(text = hover_lbl, customdata = activity_url),
        size = 1
      )
  } else {
    predicted_miles <- ytd_tbl |>
      mutate(value = (value / yr_day) * 365) |>
      select(yr, yr_lbl, yr_day, value) |>
      group_by(yr) |>
      filter(yr_day == max(yr_day) | yr_day == 1) |>
      mutate(
        value = if_else(yr_day == 1, 0, value),
        yr_day = if_else(yr_day > 1, 365, yr_day)
      ) |>
      ungroup()

    ytd_curve <- ytd_curve +
      geom_line(data = predicted_miles, linetype = "dashed", alpha = 0.5) +
      geom_point(
        data = ytd_tbl |> filter(ytd_val),
        aes(text = hover_lbl, customdata = activity_url),
        size = 1
      )
  }

  ytd_curve <- plotly::ggplotly(ytd_curve, tooltip = "text")

  # Render custom JS
  ytd_curve <- ytd_curve |>
    htmlwidgets::onRender(
      "
       function(el, x) {
       
         el.on('plotly_click', function(data) {
           // retrieve url from the customdata field passed to ggplot
           var url = data.points[0].customdata;
           // open this url in the same window
           window.open(url, \"_blank\");
         });
       
       }"
    )

  return(ytd_curve)
}


get_coord_valuebox <- function(pos_needed, position_extremities) {
  positions <- position_extremities |>
    filter(extremity == pos_needed) |>
    mutate(
      city_name = case_when(
        !is.na(hamlet) ~ hamlet,
        !is.na(village) ~ village,
        !is.na(town) ~ town,
        !is.na(neighbourhood) ~ neighbourhood,
        !is.na(suburb) ~ suburb,
        !is.na(city) ~ city
      )
    ) |>
    slice_head(n = 1)

  if (pos_needed == "N") {
    icon_str <- "fa-arrow-up"
  }

  if (pos_needed == "S") {
    icon_str <- "fa-arrow-down"
  }

  if (pos_needed == "E") {
    icon_str <- "fa-arrow-right"
  }

  if (pos_needed == "W") {
    icon_str <- "fa-arrow-left"
  }

  link_str <- str_glue(
    "https://www.google.com/maps/place/{positions$latitude}N+{if_else(positions$longitude>0,str_c(positions$longitude,\"E\"),str_c(0 - positions$longitude,\"W\"))}"
  )
  vb <- valueBox(
    positions$city_name,
    icon = icon_str,
    color = "#EDF0F1",
    href = link_str
  )
  return(vb)
}

add_track <- function(
  leaflet_obj,
  position_tbl,
  lat_lng_names = c("latitude", "longitude"),
  track_colour = "#0C2340"
) {
  latitude <- position_tbl[[lat_lng_names[1]]]
  longitude <- position_tbl[[lat_lng_names[2]]]

  leaflet_obj <- leaflet::addPolylines(
    map = leaflet_obj,
    lat = latitude,
    lng = longitude,
    opacity = 0.5,
    weight = 2,
    color = track_colour
  )

  return(leaflet_obj)
}

draw_map <- function(streams_tbl) {
  if ("sport_type" %in% names(streams_tbl)) {
    streams_tbl <- streams_tbl |>
      filter(sport_type == "Ride")
  }

  if ("stream_order" %in% names(streams_tbl)) {
    streams_tbl <- streams_tbl |>
      arrange(activity_id, stream_order)
  } else {
    streams_tbl <- streams_tbl |>
      arrange(activity_id)
  }

  map <- leaflet() |>
    addTiles(
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_labels_under/{z}/{x}/{y}.png',
      attribution = paste(
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors',
        '&copy; <a href="https://cartodb.com/attributions">CartoDB</a>'
      )
    )

  tracks <- split(streams_tbl, streams_tbl$activity_id)

  map <-
    tracks |>
    reduce(
      \(map, track) map |> add_track(track),
      .init = map
    )

  return(map)
}


draw_critical_metric_curve <- function(metric_to_plot, con) {
  if (!metric_to_plot %in% peaks_units$display_name) {
    stop(str_glue(
      "Invalid metric supplied; allowed values are '{str_flatten(peaks_units$display_name, collapse = \"', '\")}'"
    ))
  }

  units <- peaks_units |> filter(display_name == metric_to_plot)

  # Get all time peaks
  # Calculate best ever, best last year, best this year
  query <- "
        SELECT
          abe.activity_id,
          a.start_date_local,
          a.sport_type,
          abe.metric_name,
          abe.peak_value,
          abe.duration_seconds,
          'All time' as peak_period
        FROM
          cycling_platform_gold.activity_best_efforts abe
        INNER JOIN
          cycling_platform_silver.activities a
        ON abe.activity_id = a.activity_id
        WHERE metric_name = ?
          "

  peaks_all_time <- DBI::dbGetQuery(
    conn = con,
    query,
    params = list(units$metric_name)
  )

  peaks_last_year <- peaks_all_time |>
    filter(year(start_date_local) == year(Sys.Date() - years(1))) |>
    mutate(peak_period = "Last year")

  peaks_cur_year <- peaks_all_time |>
    filter(year(start_date_local) == year(Sys.Date())) |>
    mutate(peak_period = "Current year")

  best_peaks <- bind_rows(peaks_all_time, peaks_last_year, peaks_cur_year) |>
    filter(!(sport_type == "VirtualRide" & metric_name == "velocity_smooth")) |> # exclude speed metrics from virtual rides
    group_by(peak_period, metric_name, duration_seconds) |>
    slice_max(peak_value, n = 3, with_ties = F) |>
    mutate(
      rank = rank(-peak_value),
      peak_value = peak_value * local(units$multiplier)
    ) |>
    left_join(peaks_units, by = "metric_name") |>
    mutate(
      duration_seconds_fct = if_else(
        duration_seconds < 60,
        str_c(duration_seconds, 's'),
        str_c(duration_seconds / 60, 'min')
      ),
      duration_seconds_fct = factor(duration_seconds_fct),
      duration_seconds_fct = fct_reorder(
        duration_seconds_fct,
        duration_seconds
      ),
      activity_url = str_glue(
        "https://www.strava.com/activities/{activity_id}"
      ),
      hover_lbl = str_glue(
        "Best {duration_seconds_fct} {display_name} - {peak_period}
                              {round(peak_value, digits = 1)}{units}"
      )
    )

  peaks_plot <- best_peaks %>%
    filter(display_name == metric_to_plot, rank == 1) %>%
    ggplot(aes(
      x = duration_seconds_fct,
      y = peak_value,
      colour = peak_period,
      fill = peak_period,
      group = peak_period
    )) +
    geom_point(aes(text = hover_lbl, customdata = activity_url)) +
    geom_area(position = "identity", alpha = 0.2) +
    theme_minimal() +
    theme(legend.position = "none") +
    labs(
      x = "",
      y = str_glue("{str_to_title(metric_to_plot)} /{local(units$units)}\n")
    )

  peaks_plot <- plotly::ggplotly(peaks_plot, tooltip = "text")

  # Render custom JS
  peaks_plot <- peaks_plot %>%
    htmlwidgets::onRender(
      "
       function(el, x) {
       
         el.on('plotly_click', function(data) {
           // retrieve url from the customdata field passed to ggplot
           var url = data.points[0].customdata;
           // open this url in the same window
           window.open(url, \"_blank\");
         });
       
       }"
    )

  return(peaks_plot)
}
