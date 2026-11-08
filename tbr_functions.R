# TBR Family Adventures presentation model --------------------------------

TBR_METRES_PER_MILE <- 1609.344

empty_tbr_activities <- function() {
  tibble::tibble(
    activity_id = character(),
    activity_name = character(),
    sport_type = character(),
    gear_id = character(),
    start_datetime_local = as.POSIXct(character()),
    start_date_local = as.Date(character()),
    distance_metres = double(),
    moving_time_seconds = double()
  )
}

empty_tbr_position_streams <- function() {
  tibble::tibble(
    activity_id = character(),
    sample_index = integer(),
    latitude = double(),
    longitude = double()
  )
}

select_tbr_activities <- function(activities) {
  required <- c(
    "activity_id", "activity_name", "sport_type", "start_datetime_local"
  )
  if (!all(required %in% names(activities))) {
    stop(
      "TBR selection requires: ",
      paste(required, collapse = ", "),
      call. = FALSE
    )
  }

  activities |>
    dplyr::filter(
      .data$sport_type == "Ride",
      !is.na(.data$activity_name),
      stringr::str_detect(.data$activity_name, stringr::regex("tbr", TRUE))
    ) |>
    dplyr::arrange(.data$start_datetime_local, .data$activity_id) |>
    dplyr::distinct(.data$activity_id, .keep_all = TRUE)
}

get_tbr_activities <- function(con) {
  result <- DBI::dbGetQuery(
    con,
    "SELECT activity_id, activity_name, sport_type, gear_id,
      start_datetime_local, start_date_local, distance_metres,
      moving_time_seconds
    FROM cycling_platform_silver.activities
    WHERE sport_type = 'Ride'
      AND LOWER(activity_name) LIKE '%tbr%'
    ORDER BY start_datetime_local, activity_id"
  ) |>
    tibble::as_tibble()

  if (nrow(result) == 0L) empty_tbr_activities() else result
}

get_tbr_position_streams <- function(con, activity_ids) {
  activity_ids <- unique(as.character(activity_ids[!is.na(activity_ids)]))
  if (length(activity_ids) == 0L) {
    return(empty_tbr_position_streams())
  }

  placeholders <- paste(rep("?", length(activity_ids)), collapse = ", ")
  DBI::dbGetQuery(
    con,
    paste0(
      "SELECT activity_id, sample_index, latitude, longitude\n",
      "FROM cycling_platform_silver.activity_streams\n",
      "WHERE activity_id IN (", placeholders, ")\n",
      "ORDER BY activity_id, sample_index"
    ),
    params = as.list(activity_ids)
  ) |>
    tibble::as_tibble()
}

build_tbr_summary <- function(activities) {
  if (nrow(activities) == 0L) {
    return(list(
      adventures = 0L,
      distance_miles = 0,
      moving_time_seconds = 0,
      first_adventure_date = as.Date(NA),
      longest_distance_miles = NA_real_,
      longest_activity_id = NA_character_
    ))
  }

  ordered <- activities |>
    dplyr::arrange(.data$start_datetime_local, .data$activity_id)
  valid_distance <- which(!is.na(ordered$distance_metres))
  longest_index <- if (length(valid_distance)) {
    valid_distance[[which.max(ordered$distance_metres[valid_distance])]]
  } else {
    NA_integer_
  }

  list(
    adventures = nrow(ordered),
    distance_miles = sum(ordered$distance_metres, na.rm = TRUE) /
      TBR_METRES_PER_MILE,
    moving_time_seconds = sum(ordered$moving_time_seconds, na.rm = TRUE),
    first_adventure_date = as.Date(ordered$start_date_local[[1]]),
    longest_distance_miles = if (is.na(longest_index)) NA_real_ else
      ordered$distance_metres[[longest_index]] / TBR_METRES_PER_MILE,
    longest_activity_id = if (is.na(longest_index)) NA_character_ else
      as.character(ordered$activity_id[[longest_index]])
  )
}

format_tbr_duration <- function(seconds) {
  if (length(seconds) == 0L || is.na(seconds)) return("—")
  hours <- floor(seconds / 3600)
  minutes <- floor((seconds %% 3600) / 60)
  if (hours > 0) sprintf("%d hr %02d min", hours, minutes) else
    sprintf("%d min", minutes)
}

build_tbr_calendar <- function(activities, reference_date = Sys.Date()) {
  if (nrow(activities) == 0L) {
    return(tibble::tibble(
      year = integer(), month = integer(), month_label = character(),
      adventures = integer(), distance_miles = double(),
      month_start = as.Date(character()), is_future = logical()
    ))
  }

  dates <- as.Date(activities$start_date_local)
  years <- seq(min(lubridate::year(dates)), max(lubridate::year(dates)))
  monthly <- activities |>
    dplyr::mutate(
      year = lubridate::year(.data$start_date_local),
      month = lubridate::month(.data$start_date_local)
    ) |>
    dplyr::group_by(.data$year, .data$month) |>
    dplyr::summarise(
      adventures = dplyr::n(),
      distance_miles = sum(.data$distance_metres, na.rm = TRUE) /
        TBR_METRES_PER_MILE,
      .groups = "drop"
    )

  tidyr::expand_grid(year = years, month = 1:12) |>
    dplyr::left_join(monthly, by = c("year", "month")) |>
    dplyr::mutate(
      adventures = tidyr::replace_na(.data$adventures, 0L),
      distance_miles = tidyr::replace_na(.data$distance_miles, 0),
      month_start = as.Date(sprintf("%04d-%02d-01", .data$year, .data$month)),
      month_label = month.abb[.data$month],
      is_future = .data$month_start > lubridate::floor_date(
        as.Date(reference_date), "month"
      )
    ) |>
    dplyr::arrange(.data$year, .data$month)
}

draw_tbr_calendar <- function(calendar) {
  if (nrow(calendar) == 0L) {
    return(latest_ride_notice("No family adventures are available yet."))
  }

  plot_data <- calendar |>
    dplyr::mutate(
      year_label = factor(.data$year, levels = rev(sort(unique(.data$year)))),
      fill_value = ifelse(.data$is_future, NA_real_, .data$adventures),
      hover = dplyr::if_else(
        .data$is_future,
        paste0(.data$month_label, " ", .data$year, ": future month"),
        sprintf(
          "%s %d<br>%d adventure%s<br>%.1f miles",
          .data$month_label,
          .data$year,
          .data$adventures,
          ifelse(.data$adventures == 1L, "", "s"),
          .data$distance_miles
        )
      )
    )

  chart <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(
      x = factor(.data$month_label, levels = month.abb),
      y = .data$year_label,
      fill = .data$fill_value,
      text = .data$hover
    )
  ) +
    ggplot2::geom_tile(colour = "white", linewidth = 1) +
    ggplot2::scale_fill_gradient(
      low = "#EDF0F1",
      high = "#17324D",
      na.value = "#D8DDE0",
      breaks = scales::breaks_pretty(n = 4)
    ) +
    ggplot2::labs(x = NULL, y = NULL, fill = "Adventures") +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      legend.position = "bottom",
      axis.text.x = ggplot2::element_text(angle = 0)
    )

  plotly::ggplotly(chart, tooltip = "text") |>
    plotly::layout(margin = list(l = 45, r = 15, b = 35, t = 10))
}

build_tbr_milestones <- function(activities) {
  if (nrow(activities) == 0L) {
    return(tibble::tibble(
      milestone_date = as.Date(character()),
      milestone_order = integer(),
      label = character()
    ))
  }

  ordered <- activities |>
    dplyr::arrange(.data$start_datetime_local, .data$activity_id) |>
    dplyr::mutate(
      adventure_number = dplyr::row_number(),
      distance_miles = tidyr::replace_na(.data$distance_metres, 0) /
        TBR_METRES_PER_MILE,
      cumulative_miles = cumsum(.data$distance_miles),
      milestone_date = as.Date(.data$start_date_local)
    )

  milestone_rows <- list(tibble::tibble(
    milestone_date = ordered$milestone_date[[1]],
    milestone_order = 1L,
    label = "Our first adventure"
  ))

  count_thresholds <- c(10L, 25L, 50L, 100L)
  reached_counts <- count_thresholds[count_thresholds <= nrow(ordered)]
  if (length(reached_counts)) {
    milestone_rows[[length(milestone_rows) + 1L]] <- tibble::tibble(
      milestone_date = ordered$milestone_date[reached_counts],
      milestone_order = reached_counts,
      label = paste(reached_counts, "adventures together")
    )
  }

  distance_thresholds <- c(100, 250, 500, 1000)
  reached_distances <- distance_thresholds[
    distance_thresholds <= max(ordered$cumulative_miles)
  ]
  if (length(reached_distances)) {
    crossing_indexes <- vapply(
      reached_distances,
      function(threshold) which(ordered$cumulative_miles >= threshold)[[1]],
      integer(1)
    )
    milestone_rows[[length(milestone_rows) + 1L]] <- tibble::tibble(
      milestone_date = ordered$milestone_date[crossing_indexes],
      milestone_order = crossing_indexes,
      label = paste(format(reached_distances, big.mark = ","), "miles together")
    )
  }

  valid_distance <- ordered |>
    dplyr::filter(!is.na(.data$distance_metres)) |>
    dplyr::arrange(
      dplyr::desc(.data$distance_metres),
      .data$start_datetime_local,
      .data$activity_id
    )
  if (nrow(valid_distance)) {
    milestone_rows[[length(milestone_rows) + 1L]] <- tibble::tibble(
      milestone_date = valid_distance$milestone_date[[1]],
      milestone_order = valid_distance$adventure_number[[1]],
      label = sprintf(
        "Longest adventure — %.1f miles",
        valid_distance$distance_miles[[1]]
      )
    )
  }

  monthly <- ordered |>
    dplyr::mutate(month_start = lubridate::floor_date(.data$milestone_date, "month")) |>
    dplyr::group_by(.data$month_start) |>
    dplyr::summarise(
      adventures = dplyr::n(),
      distance_miles = sum(.data$distance_miles),
      milestone_order = min(.data$adventure_number),
      .groups = "drop"
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$adventures),
      dplyr::desc(.data$distance_miles),
      .data$month_start
    )
  most_active <- monthly[1, ]
  milestone_rows[[length(milestone_rows) + 1L]] <- tibble::tibble(
    milestone_date = as.Date(most_active$month_start),
    milestone_order = most_active$milestone_order,
    label = sprintf(
      "Most active month — %s (%d adventures, %.1f miles)",
      format(most_active$month_start, "%B %Y"),
      most_active$adventures,
      most_active$distance_miles
    )
  )

  dplyr::bind_rows(milestone_rows) |>
    dplyr::arrange(.data$milestone_date, .data$milestone_order, .data$label)
}

render_tbr_milestones <- function(milestones) {
  if (nrow(milestones) == 0L) {
    return(latest_ride_notice("Milestones will appear as adventures accumulate."))
  }

  htmltools::div(
    class = "tbr-milestones",
    lapply(seq_len(nrow(milestones)), function(index) {
      htmltools::div(
        class = "tbr-milestone",
        htmltools::span(
          class = "tbr-milestone-date",
          format(milestones$milestone_date[[index]], "%d %b %Y")
        ),
        htmltools::span(milestones$label[[index]])
      )
    })
  )
}

prepare_tbr_route <- function(streams) {
  prepared <- prepare_latest_ride_route(streams)
  if (!isTRUE(prepared$eligible)) return(prepared)

  prepared$line_segments <- purrr::keep(
    prepared$line_segments,
    function(segment) {
      nrow(dplyr::distinct(segment, .data$latitude, .data$longitude)) >= 2L
    }
  )
  prepared$eligible <- length(prepared$line_segments) > 0L
  prepared
}

build_tbr_map_model <- function(activities, streams) {
  if (nrow(activities) == 0L) {
    return(list(routes = list(), latest_mapped_activity_id = NA_character_, unmapped = 0L))
  }

  ordered <- activities |>
    dplyr::arrange(.data$start_datetime_local, .data$activity_id)
  stream_groups <- split(streams, as.character(streams$activity_id))
  routes <- list()

  for (index in seq_len(nrow(ordered))) {
    activity_id <- as.character(ordered$activity_id[[index]])
    activity_streams <- stream_groups[[activity_id]]
    if (is.null(activity_streams)) next
    prepared <- prepare_tbr_route(activity_streams)
    if (!isTRUE(prepared$eligible)) next

    routes[[activity_id]] <- list(
      activity = ordered[index, , drop = FALSE],
      segments = prepared$line_segments
    )
  }

  mapped_ids <- names(routes)
  list(
    routes = routes,
    latest_mapped_activity_id = if (length(mapped_ids)) tail(mapped_ids, 1) else NA_character_,
    unmapped = nrow(ordered) - length(mapped_ids)
  )
}

tbr_route_popup <- function(activity) {
  name <- htmltools::htmlEscape(as.character(activity$activity_name[[1]]))
  date <- format(as.Date(activity$start_date_local[[1]]), "%d %B %Y")
  distance <- if (is.na(activity$distance_metres[[1]])) "Distance unavailable" else
    sprintf("%.1f miles", activity$distance_metres[[1]] / TBR_METRES_PER_MILE)
  activity_id <- utils::URLencode(as.character(activity$activity_id[[1]]), reserved = TRUE)
  paste0(
    "<strong>", name, "</strong><br>",
    htmltools::htmlEscape(date), "<br>",
    htmltools::htmlEscape(distance), "<br>",
    '<a href="https://www.strava.com/activities/', activity_id,
    '" target="_blank" rel="noopener noreferrer">View on Strava</a>'
  )
}

draw_tbr_adventure_map <- function(activities, streams) {
  if (nrow(activities) == 0L) {
    return(latest_ride_notice("No family adventures are available yet."))
  }
  model <- build_tbr_map_model(activities, streams)
  if (length(model$routes) == 0L) {
    return(latest_ride_notice(
      "Our adventures are recorded, but none currently has usable route geometry."
    ))
  }

  map <- leaflet::leaflet() |>
    leaflet::addTiles(
      carto_basemap_tile_url("voyager_labels_under"),
      attribution = paste(
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors',
        '&copy; <a href="https://carto.com/attributions">CARTO</a>'
      )
    )

  for (activity_id in names(model$routes)) {
    route <- model$routes[[activity_id]]
    is_latest_mapped <- identical(activity_id, model$latest_mapped_activity_id)
    popup <- tbr_route_popup(route$activity)
    for (segment_index in seq_along(route$segments)) {
      segment <- route$segments[[segment_index]]
      map <- leaflet::addPolylines(
        map,
        data = segment,
        lng = ~longitude,
        lat = ~latitude,
        color = if (is_latest_mapped) "#17324D" else "#89A7BF",
        weight = if (is_latest_mapped) 4 else 2,
        opacity = if (is_latest_mapped) 0.95 else 0.28,
        popup = popup,
        layerId = paste0("tbr-", activity_id, "-", segment_index)
      )
    }
  }

  latest_route <- model$routes[[model$latest_mapped_activity_id]]$activity
  label <- paste0(
    "Latest mapped adventure: ",
    format(as.Date(latest_route$start_date_local[[1]]), "%d %b %Y")
  )
  if (model$unmapped > 0L) {
    label <- paste0(
      label,
      "<br>",
      model$unmapped,
      " adventure",
      ifelse(model$unmapped == 1L, "", "s"),
      " not mapped"
    )
  }
  leaflet::addControl(
    map,
    html = label,
    position = "topright",
    className = "tbr-map-status"
  )
}
