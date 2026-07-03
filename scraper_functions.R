# Scraper functions -------------------------------------------------------

# # Repoint once table built
# get_ftp_values <- function(con) {
#   ftp <- dplyr::tbl(con, "ftp_history") %>%
#     dplyr::collect() %>%
#     dplyr::mutate(
#       ftp_from = ftp_date,
#       ftp_to = lead(ftp_date),
#       latest = ftp_from == max(ftp_from)
#     ) %>%
#     tidyr::replace_na(list(ftp_to = Sys.time())) %>%
#     dplyr::select(-ftp_id, -ftp_date)

#   return(ftp)
# }

# # Is this needed?
# clean_stream_data <- function(stream, metrics_to_clean, gap_size_to_fill = 10) {
#   cleaned_stream <- tibble(time = seq(0, max(stream$time), 1)) %>%
#     left_join(distinct(stream), by = "time") %>%
#     pivot_longer(cols = all_of(metrics_to_clean), names_to = "metric") %>%
#     fill(-c(metric, value), .direction = "down") %>%
#     arrange(metric, time) %>%
#     group_by(metric) %>%
#     mutate(
#       has_data = !is.na(value),
#       has_data_group_id = str_c(metric, time),
#       prev_has_data = lag(has_data),
#       has_data_group_id = case_when(
#         is.na(prev_has_data) ~ has_data_group_id,
#         has_data != prev_has_data ~ has_data_group_id,
#         T ~ NA_character_
#       )
#     ) %>%
#     fill(has_data_group_id, .direction = "down") %>%
#     ungroup() %>%
#     group_by(has_data_group_id) %>%
#     mutate(group_size = n(), val2 = value) %>%
#     ungroup() %>%
#     fill(val2, .direction = "down") %>%
#     mutate(
#       value = case_when(
#         is.na(value) & group_size <= gap_size_to_fill ~ val2,
#         is.na(value) ~ 0,
#         T ~ value
#       )
#     ) %>%
#     replace_na(list(value = 0)) %>%
#     select(-matches("has_data"), -group_size, -val2) %>%
#     pivot_wider(names_from = "metric", values_from = "value") %>%
#     mutate(
#       moving = case_when(
#         watts > 0 ~ T,
#         moving == 1 & velocity_smooth > 2 ~ T,
#         .default = F
#       )
#     )

#   return(cleaned_stream)
# }

# This moves to cycling-platform project for gold transform
calculate_activity_peaks <- function(
  activity_id,
  con,
  peaks_for = c("cadence", "heartrate", "watts", "velocity_smooth"),
  peak_time_ranges = c(
    5,
    10,
    12,
    20,
    30,
    60,
    120,
    300,
    360,
    600,
    720,
    1200,
    1800,
    3600
  )
) {
  # Get activity data
  activities <- tbl(con, "activities") %>%
    select(strava_id, distance, start_date_local, sport_type) %>%
    collect()

  # Get stream for activity
  stream_sql <- dplyr::tbl(con, "streams") %>%
    dplyr::inner_join(
      dplyr::tbl(con, "activities") %>%
        dplyr::select(
          strava_id,
          moving_time,
          sport_type,
          start_date_local
        ),
      by = "strava_id"
    ) %>%
    dplyr::filter(strava_id == activity_id) %>%
    dplyr::mutate(
      moving_time = moving_time,
      sport_type = sport_type
    ) %>%
    dplyr::select(
      moving_time,
      moving,
      time,
      sport_type,
      dplyr::all_of(peaks_for)
    ) %>%
    dplyr::collect()

  peak_time_ranges <- peak_time_ranges[
    peak_time_ranges <= max(stream_sql$moving_time)
  ]

  # Get all time peaks
  # Calculate best ever and best this year
  peaks_sql <- tbl(con, "vw_training_peaks") %>%
    filter(peak > 0) %>%
    collect()

  if (activity_id %in% peaks_sql$strava_id) {
    stop(str_glue(
      "Activity ID {activity_id} has already had peaks calculated. Remove from SQL table if re-calculation required."
    ))
  }

  best_peaks <- peaks_sql %>%
    filter(year(start_date_local) == year(Sys.Date())) %>%
    mutate(peak_period = "Current year") %>%
    bind_rows(peaks_sql %>% mutate(peak_period = "All time")) %>%
    filter(!(sport_type == "VirtualRide" & metric == "velocity_smooth")) %>% # exclude speed metrics from virtual rides
    group_by(peak_period, metric, time_range) %>%
    slice_max(peak, n = 3, with_ties = F) %>%
    mutate(rank = rank(-peak))

  # Create distance "peaks", combine with other peaks (exclude current activity so it isn't compared
  # to itself)
  distance_peaks <- bind_rows(
    activities %>%
      filter(strava_id != activity_id) %>%
      slice_max(distance, n = 3) %>%
      mutate(peak_period = "All time", rank = row_number()),
    activities %>%
      filter(
        strava_id != activity_id,
        year(start_date_local) == year(Sys.Date())
      ) %>%
      slice_max(distance, n = 3) %>%
      mutate(peak_period = "Current year", rank = row_number())
  ) %>%
    mutate(metric = "distance") %>%
    select(
      strava_id,
      metric,
      peak = distance,
      start_date_local,
      sport_type,
      peak_period,
      rank
    )

  best_peaks <- bind_rows(best_peaks, distance_peaks)

  # Ensure a row present for every second of the entire activity (no data recorded when stopped)
  # Then establish the width of any data gaps for later smoothing
  # Large data gaps will mean bike stopped - values should be set to zero - but small gaps can be filled
  peaks <- clean_stream_data(stream_sql, peaks_for)

  peaks <- peaks %>%
    pivot_longer(all_of(peaks_for), names_to = "metric") %>%
    filter(!(sport_type == "VirtualRide" & metric == "velocity_smooth")) %>% # exclude speed metrics from virtual rides
    nest(data = !metric) %>%
    crossing(time_range = peak_time_ranges) %>%
    mutate(
      strava_id = activity_id,
      time_range_means = map2(
        data,
        time_range,
        ~ slide_dbl(.x$value, .f = mean, .after = (.y - 1), .complete = T)
      ),
      peak = map_dbl(time_range_means, ~ max(., na.rm = T))
    ) %>%
    select(strava_id, metric, time_range, peak)

  # Bind on distance "peak" for activity in question
  distance_peak <- activities %>%
    filter(strava_id == activity_id) %>%
    mutate(metric = "distance") %>%
    select(strava_id, metric, peak = distance)

  peaks <- bind_rows(peaks, distance_peak)

  # Compare peaks
  peaks_compare <- best_peaks %>%
    left_join(
      peaks %>% select(metric, time_range, current_peak = peak),
      by = c("metric", "time_range")
    ) %>%
    filter(current_peak > peak) %>%
    slice_min(rank) %>%
    left_join(peaks_units, by = "metric") %>%
    mutate(
      msg_period = str_glue("\n\n{peak_period}:\n\n"),
      msg = str_glue(
        "- {if_else(rank == 1,'B',str_c(scales::ordinal(rank), ' b'))}est {if_else(time_range < 60, str_c(time_range,'s'), str_c(time_range/60,'min'))} {display_name} - {round(current_peak*multiplier,1)}{units}\n\n"
      ),
      msg = str_remove(msg, "NA ")
    )

  # Notification of new peaks
  if (nrow(peaks_compare) > 0) {
    peaks_ntfy_msg <- peaks_compare %>%
      group_by(msg_period) %>%
      summarise(msg = str_flatten(msg)) %>%
      pivot_longer(everything()) %>%
      summarise(msg = str_flatten(value)) %>%
      pull(msg)

    send_ntfy_message(
      msg_body = peaks_ntfy_msg,
      msg_title = "New peaks found!",
      msg_tags = "fire,muscle"
    )
  }

  # Notification of new FTP
  ftp <- get_ftp_values(con) %>%
    filter(latest) %>%
    pull(ftp)

  if (max(peak_time_ranges) >= 1200) {
    best_20min_w <- peaks %>%
      filter(metric == "watts", time_range == 1200) %>%
      pull(peak)

    if (0.95 * best_20min_w > ftp) {
      send_ntfy_message(
        msg_title = "New FTP found!",
        msg_body = str_glue("New FTP: {round(0.95*best_20min_w)}w"),
        msg_tags = "fire,fire,fire"
      )
    }
  }

  # Append to peaks table
  dbWriteTable(con, "peaks", peaks %>% filter(metric != "distance"), append = T)

  log_message(glue::glue(
    "Peak efforts for activity {activity_id} appended to database."
  ))
}

# Also one for cycling-platform
calculate_power_summary <- function(activity_id, con) {
  power_summaries_loaded <- tbl(con, "power_summaries") %>%
    select(strava_id) %>%
    distinct() %>%
    pull(strava_id)

  activity_stream <- tbl(con, "vw_streams") %>%
    select(
      strava_id,
      start_date_local,
      sport_type,
      time,
      moving_time,
      moving,
      watts,
      velocity_smooth
    ) %>%
    filter(strava_id == activity_id) %>%
    collect()

  stream_cleaned <- clean_stream_data(activity_stream, c("watts"))

  power_summary <- stream_cleaned %>%
    filter(moving) %>%
    mutate(start_date_local = as.POSIXct(start_date_local)) %>%
    left_join(
      get_ftp_values(con),
      by = join_by(between(start_date_local, ftp_from, ftp_to))
    ) %>%
    group_by(strava_id, start_date_local, ftp, moving_time) %>%
    mutate(
      mean_power_30s = slide_dbl(watts, .f = mean, .before = 29, .complete = T),
      mean_power_30s_4p = mean_power_30s^4,
      contiguous_30s = lag(time, 29) == (time - 29)
    ) %>%
    filter(contiguous_30s) %>%
    summarise(
      NP = (mean(mean_power_30s_4p, na.rm = T))^(1 / 4),
      mean_power = mean(watts, na.rm = T),
      .groups = "drop"
    ) %>%
    select(-start_date_local) %>%
    mutate(
      VI = NP / mean_power,
      IF = NP / ftp,
      TSS = ((moving_time * NP * IF) / (ftp * 3600)) * 100
    )

  if (activity_id %in% power_summaries_loaded) {
    stop(str_glue(
      "Activity ID {activity_id} has already had a power summary calculated. Remove from SQL table if re-calculation needed."
    ))
  }

  # Append to power summary table
  dbWriteTable(con, "power_summaries", power_summary, append = T)

  log_message(glue::glue(
    "Power summary efforts for activity {activity_id} appended to database."
  ))
}

draw_bbox_map <- function(
  activity_bbox,
  draw_bbox = F,
  activity_types = "Ride"
) {
  activity_id <- activity_bbox[[1]]
  bbox <- activity_bbox[[2]]

  # Limit activity ids to those of the selected types
  all_type_id <- tbl(con, "activities") %>%
    filter(type %in% activity_types) %>%
    pull(strava_id)

  activity_id <- activity_id[activity_id %in% all_type_id]

  streams <- tbl(con, "streams") %>%
    select(strava_id, lat, lng) %>%
    filter(strava_id %in% activity_id) %>%
    collect() %>%
    filter(row_number() %% 10 == 1) # select every 10th row -> speed up the plotting of the map

  # create base map
  leaflet_map <- leaflet::leaflet() %>%
    leaflet::addTiles(
      urlTemplate = "https://tiles.stadiamaps.com/tiles/outdoors/{z}/{x}/{y}{r}.png"
    )

  # Add on each ride
  for (ride_id in unique(streams$strava_id)) {
    ride_stream <- streams %>% filter(strava_id == ride_id)

    leaflet_map <- leaflet_map %>%
      leaflet::addPolylines(
        ride_stream$lng,
        ride_stream$lat,
        opacity = 1,
        weight = 2,
        color = "#48494B"
      )
  }

  # Draw on bounding boxes, if draw_bbox set to TRUE
  if (draw_bbox & !is.na(bbox)) {
    for (i in 1:length(bbox)) {
      leaflet_map <- leaflet_map %>%
        leaflet::addRectangles(
          lng1 = bbox[[i]][4],
          lat1 = bbox[[i]][2],
          lng2 = bbox[[i]][3],
          lat2 = bbox[[i]][1],
          fillColor = "transparent",
          color = "#FF0000",
          weight = 1
        )
    }
  }

  print(leaflet_map)
  print(activity_id)
}

# Ride finder functions ---------------------------------------------------

# A set of functions for finding rides, all consistently named. Each takes a vector of activity ids and returns a vector of
# activity ids so they can be daisy chained together. Simpler than having one mega function, and easier to build extra
# filtering functionality later

find_rides_starting <- function(
  con,
  activity_bbox = list(NA, NA),
  start_dates = NA,
  start_years = NA,
  start_location = NA,
  min_distance = NA_real_
) {
  # start_dates - vector of one or more dates
  # start_years - vector of one or more years
  activity_id <- activity_bbox[[1]]
  prev_bbox <- activity_bbox[[2]]

  # start_location - bounding box passed as NSEW vector, e.g. c(51, 50, 1, 0))

  if (all(is.na(activity_id))) {
    activity_id <- tbl(con, "activities") %>% pull(strava_id) %>% unique()
  }

  # If bounding box supplied (i.e. 4 element list)
  if (length(start_location) == 4) {
    bbox_north <- start_location[1]
    bbox_south <- start_location[2]
    bbox_east <- start_location[3]
    bbox_west <- start_location[4]

    if (bbox_north <= bbox_south) {
      stop(str_glue(
        "North value supplied ({bbox_north}) must be greater that South value ({bbox_south})"
      ))
    }

    if (bbox_east <= bbox_west) {
      stop(str_glue(
        "East value supplied ({bbox_east}) must be greater that West value ({bbox_west})"
      ))
    }

    activity_id <- tbl(con, "activities") %>%
      filter(
        start_lat <= bbox_north,
        start_lat >= bbox_south,
        start_lng <= bbox_east,
        start_lng >= bbox_west,
        strava_id %in% activity_id
      ) %>%
      pull(strava_id) %>%
      unique()
  }

  # If vector of dates supplied
  if (all(!is.na(start_dates))) {
    activity_id <- tbl(con, "activities") %>%
      collect() %>%
      mutate(start_date_local = as.Date(start_date_local)) %>%
      filter(start_date_local %in% start_dates, strava_id %in% activity_id) %>%
      pull(strava_id) %>%
      unique()
  }

  # If vector of years supplied
  if (!is.na(start_years)) {
    activity_id <- tbl(con, "activities") %>%
      collect() %>%
      mutate(start_yr = year(start_date_local)) %>%
      filter(start_yr %in% start_years, strava_id %in% activity_id) %>%
      pull(strava_id) %>%
      unique()
  }

  # If minimum distance supplied
  if (!is.na(min_distance)) {
    activity_id <- tbl(con, "activities") %>%
      collect() %>%
      mutate(distance_miles = distance / 1609.34) %>%
      filter(distance_miles >= min_distance, strava_id %in% activity_id) %>%
      pull(strava_id) %>%
      unique()
  }

  if (all(!is.na(prev_bbox))) {
    if (is.list(prev_bbox)) {
      prev_bbox <- append(prev_bbox, list(start_location))
    } else {
      prev_bbox <- list(prev_bbox, start_location)
    }
  } else {
    prev_bbox <- list(start_location)
  }

  activity_bbox <- list(activity_id, prev_bbox)

  return(activity_bbox)
}

find_rides_visiting <- function(
  con,
  activity_bbox = list(NA, NA),
  visiting_location = NA
) {
  activity_id <- activity_bbox[[1]]
  prev_bbox <- activity_bbox[[2]]

  # visiting_location - bounding box passed as NSEW vector, e.g. c(51, 50, 1, 0))

  if (all(is.na(activity_id))) {
    activity_id <- tbl(con, "activities") %>% pull(strava_id) %>% unique()
  }

  # If bounding box supplied (i.e. 4 element list)
  if (length(visiting_location) == 4) {
    bbox_north <- visiting_location[1]
    bbox_south <- visiting_location[2]
    bbox_east <- visiting_location[3]
    bbox_west <- visiting_location[4]

    if (bbox_north <= bbox_south) {
      stop(str_glue(
        "North value supplied ({bbox_north}) must be greater that South value ({bbox_south})"
      ))
    }

    if (bbox_east <= bbox_west) {
      stop(str_glue(
        "East value supplied ({bbox_east}) must be greater that West value ({bbox_west})"
      ))
    }

    activity_id <- tbl(con, "streams") %>%
      filter(
        lat <= bbox_north,
        lat >= bbox_south,
        lng <= bbox_east,
        lng >= bbox_west,
        strava_id %in% activity_id
      ) %>%
      pull(strava_id) %>%
      unique()
  }

  if (all(!is.na(prev_bbox))) {
    if (is.list(prev_bbox)) {
      prev_bbox <- append(prev_bbox, list(visiting_location))
    } else {
      prev_bbox <- list(prev_bbox, visiting_location)
    }
  } else {
    prev_bbox <- list(visiting_location)
  }

  activity_bbox <- list(activity_id, prev_bbox)

  return(activity_bbox)
}

# Need to build a nice map plotting function

# Visualisation functions -------------------------------------------------

# This needs to be repointed at gold best efforts table in cycling_platform_gold once built
draw_critical_metric_curve <- function(metric_to_plot, con) {
  if (!metric_to_plot %in% peaks_units$display_name) {
    stop(str_glue(
      "Invalid metric supplied; allowed values are '{str_flatten(peaks_units$display_name, collapse = \"', '\")}'"
    ))
  }

  units <- peaks_units %>% filter(display_name == metric_to_plot)

  # Get all time peaks
  # Calculate best ever, best last year, best this year
  peaks_all_time <- tbl(con, "vw_training_peaks") %>%
    filter(metric == local(units$metric)) %>%
    collect() %>%
    mutate(peak_period = "All time")

  peaks_last_year <- peaks_all_time %>%
    filter(year(start_date_local) == year(Sys.Date() - years(1))) %>%
    mutate(peak_period = "Last year")

  peaks_cur_year <- peaks_all_time %>%
    filter(year(start_date_local) == year(Sys.Date())) %>%
    mutate(peak_period = "Current year")

  best_peaks <- bind_rows(peaks_all_time, peaks_last_year, peaks_cur_year) %>%
    filter(!(sport_type == "VirtualRide" & metric == "velocity_smooth")) %>% # exclude speed metrics from virtual rides
    group_by(peak_period, metric, time_range) %>%
    slice_max(peak, n = 3, with_ties = F) %>%
    mutate(rank = rank(-peak), peak = peak * local(units$multiplier)) %>%
    left_join(peaks_units, by = "metric") %>%
    mutate(
      time_range_fct = if_else(
        time_range < 60,
        str_c(time_range, 's'),
        str_c(time_range / 60, 'min')
      ),
      time_range_fct = factor(time_range_fct),
      time_range_fct = fct_reorder(time_range_fct, time_range),
      activity_url = str_glue("https://www.strava.com/activities/{strava_id}"),
      hover_lbl = str_glue(
        "Best {time_range_fct} {display_name} - {peak_period}
                              {round(peak, digits = 1)}{units}"
      )
    )

  peaks_plot <- best_peaks %>%
    filter(display_name == metric_to_plot, rank == 1) %>%
    ggplot(aes(
      x = time_range_fct,
      y = peak,
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
        data = ytd_tbl |> filter(ton_day),
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

get_ytd_values <- function(metric_to_display, ytd_stats) {
  vals <- ytd_stats %>%
    filter(ytd_val) %>%
    select(-c(yr_day, ytd_val, yr, start_date_local)) %>%
    pivot_longer(-yr_lbl, names_to = "metric") %>%
    filter(str_detect(metric, metric_to_display)) %>%
    mutate(
      value = round(value, 1),
      yr_lbl = if_else(
        str_detect(metric, "^yr_"),
        str_replace(yr_lbl, "td", "r"),
        yr_lbl
      )
    ) %>%
    select(-metric) %>%
    deframe()

  return(vals)
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

draw_map <- function(streams_tbl) {
  map <- leaflet() %>%
    addTiles(
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_labels_under/{z}/{x}/{y}.png',
      attribution = paste(
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors',
        '&copy; <a href="https://cartodb.com/attributions">CartoDB</a>'
      )
    )

  for (i in unique(streams_tbl$strava_id)) {
    map <- map %>% add_track(streams_tbl %>% filter(strava_id == i))
  }

  return(map)
}

draw_ytd_map <- function(...) {
  map <- draw_map(...)

  return(map)
}

get_coord_valuebox <- function(pos_needed) {
  positions <- position_extremities %>%
    filter(extremity == pos_needed) %>%
    mutate(
      city_name = case_when(
        !is.na(hamlet) ~ hamlet,
        !is.na(village) ~ village,
        !is.na(town) ~ town,
        !is.na(neighbourhood) ~ neighbourhood,
        !is.na(suburb) ~ suburb,
        !is.na(city) ~ city
      )
    ) %>%
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
    "https://www.google.com/maps/place/{positions$lat}N+{if_else(positions$lng>0,str_c(positions$lng,\"E\"),str_c(0 - positions$lng,\"W\"))}"
  )
  vb <- valueBox(
    positions$city_name,
    icon = icon_str,
    color = "#EDF0F1",
    href = link_str
  )
  return(vb)
}

# Publish / notify functions ----------------------------------------------

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
