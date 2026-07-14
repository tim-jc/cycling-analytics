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
    href = str_glue("https://www.strava.com/activities/{latest_ride$activity_id}")
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
    return(valueBox("No goal", icon = "fa-arrows-left-right", color = "#EDF0F1"))
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
    str_glue("{round(abs(pace_delta_mi), 0)} mi {if_else(pace_delta_mi >= 0, 'ahead', 'behind')}"),
    icon = icon_str,
    color = "#EDF0F1"
  )
}

get_ride_mix_valuebox <- function(activity_summary) {
  split_tbl <- activity_summary |>
    filter(year(start_date_local) == year(Sys.Date())) |>
    mutate(ride_type = if_else(sport_type == "VirtualRide", "indoor", "outdoor")) |>
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
      hover_lbl = str_glue("{start_date_local}
{round(distance_mi, 1)} mi")
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
  streams_tbl <- streams_tbl |>
    filter(sport_type == "Ride")

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
