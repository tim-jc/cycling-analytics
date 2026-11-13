# TBR Family Adventures presentation model --------------------------------

TBR_METRES_PER_MILE <- 1609.344
TBR_FOCUS_DISTANCE_KM <- 25
TBR_FOCUS_MIN_CLUSTER_SIZE <- 2L
TBR_FOCUS_MAX_AREA_CONTROLS <- 6L
TBR_FOCUS_MAX_OUTLIER_CONTROLS <- 3L
TBR_FOCUS_VIEWPORT_PADDING_PX <- 24L
TBR_FOCUS_LATEST_MAX_ZOOM <- 14L
TBR_FOCUS_AREA_MAX_ZOOM <- 12L
TBR_FOCUS_ALL_MAX_ZOOM <- 10L
TBR_FOCUS_GEOCODE_DECIMALS <- 3L
TBR_FOCUS_LOCALITY_FIELDS <- c(
  "borough", "city_district", "municipality", "town", "city", "county",
  "state_district", "state"
)
TBR_HISTORICAL_ROUTE_COLOR <- "#8BA9B7"
TBR_HISTORICAL_ROUTE_WEIGHT <- 2.5
TBR_HISTORICAL_ROUTE_OPACITY <- 0.50
TBR_LATEST_ROUTE_COLOR <- "#D18B58"
TBR_LATEST_ROUTE_WEIGHT <- 4.5
TBR_LATEST_ROUTE_OPACITY <- 1

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
    ggplot2::geom_tile(colour = PLOTLY_CANVAS_DARK, linewidth = 1) +
    ggplot2::scale_fill_gradient(
      low = PLOTLY_GRID_LINE,
      high = PLOTLY_COPPER,
      na.value = "#2B3F49",
      breaks = scales::breaks_pretty(n = 4)
    ) +
    ggplot2::labs(x = NULL, y = NULL, fill = "Adventures") +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      panel.grid = ggplot2::element_blank(),
      legend.position = "none",
      axis.text.x = ggplot2::element_text(angle = 0)
    )

  plotly::ggplotly(chart, tooltip = "text") |>
    plotly::layout(margin = list(l = 45, r = 15, b = 35, t = 10)) |>
    apply_navigation_instrument_plotly()
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

tbr_haversine_km <- function(latitude_from, longitude_from, latitude_to, longitude_to) {
  earth_radius_km <- 6371.0088
  to_radians <- pi / 180
  latitude_from <- latitude_from * to_radians
  latitude_to <- latitude_to * to_radians
  latitude_delta <- latitude_to - latitude_from
  longitude_delta <- (longitude_to - longitude_from) * to_radians
  haversine <- sin(latitude_delta / 2)^2 +
    cos(latitude_from) * cos(latitude_to) * sin(longitude_delta / 2)^2
  haversine <- pmin(1, pmax(0, haversine))
  2 * earth_radius_km * atan2(sqrt(haversine), sqrt(1 - haversine))
}

tbr_representative_distance_matrix <- function(representatives) {
  count <- nrow(representatives)
  distances <- matrix(0, nrow = count, ncol = count)
  if (count < 2L) return(distances)

  for (from in seq_len(count - 1L)) {
    to <- seq.int(from + 1L, count)
    values <- tbr_haversine_km(
      representatives$latitude[[from]],
      representatives$longitude[[from]],
      representatives$latitude[to],
      representatives$longitude[to]
    )
    distances[from, to] <- values
    distances[to, from] <- values
  }
  distances
}

discover_tbr_focus_areas <- function(
  representatives,
  distance_km = TBR_FOCUS_DISTANCE_KM,
  min_cluster_size = TBR_FOCUS_MIN_CLUSTER_SIZE,
  max_area_controls = TBR_FOCUS_MAX_AREA_CONTROLS,
  max_outlier_controls = TBR_FOCUS_MAX_OUTLIER_CONTROLS,
  latest_mapped_activity_id = NA_character_
) {
  if (distance_km <= 0 || min_cluster_size < 1L ||
      max_area_controls < 0L || max_outlier_controls < 0L) {
    stop("TBR focus-area parameters must be positive or zero where applicable.", call. = FALSE)
  }
  if (nrow(representatives) == 0L) {
    return(list(assignments = tibble::tibble(), controls = tibble::tibble()))
  }

  ordered <- representatives |>
    dplyr::arrange(.data$activity_id)
  if (nrow(ordered) == 1L) {
    cluster_ids <- 1L
  } else {
    cluster_ids <- stats::cutree(
      stats::hclust(
        stats::as.dist(tbr_representative_distance_matrix(ordered)),
        method = "complete"
      ),
      h = distance_km
    )
  }
  ordered$cluster_id <- as.integer(cluster_ids)

  cluster_summary <- ordered |>
    dplyr::group_by(.data$cluster_id) |>
    dplyr::summarise(
      activity_count = dplyr::n(),
      first_start = min(.data$start_datetime_local),
      first_activity_id = min(.data$activity_id),
      .groups = "drop"
    )
  meaningful <- cluster_summary |>
    dplyr::filter(.data$activity_count >= min_cluster_size) |>
    dplyr::arrange(
      .data$first_start,
      .data$first_activity_id,
      .data$cluster_id
    ) |>
    dplyr::slice_head(n = max_area_controls) |>
    dplyr::mutate(
      control_type = "area",
      control_label = paste("Area", dplyr::row_number())
    )

  assignments <- ordered |>
    dplyr::left_join(
      dplyr::select(
        meaningful,
        "cluster_id",
        "control_type",
        "control_label"
      ),
      by = "cluster_id"
    )

  outliers <- assignments |>
    dplyr::filter(
      is.na(.data$control_type),
      .data$activity_id != as.character(latest_mapped_activity_id)
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$start_datetime_local),
      dplyr::desc(.data$activity_id)
    ) |>
    dplyr::slice_head(n = max_outlier_controls) |>
    dplyr::mutate(
      control_type = "outlier",
      control_label = paste("One-off", dplyr::row_number())
    )

  if (nrow(outliers)) {
    outlier_labels <- dplyr::select(
      outliers,
      "activity_id",
      "control_type",
      "control_label"
    )
    assignments <- assignments |>
      dplyr::select(-dplyr::all_of(c("control_type", "control_label"))) |>
      dplyr::left_join(outlier_labels, by = "activity_id") |>
      dplyr::left_join(
        dplyr::select(
          meaningful,
          "cluster_id",
          area_control_type = "control_type",
          area_control_label = "control_label"
        ),
        by = "cluster_id"
      ) |>
      dplyr::mutate(
        control_type = dplyr::coalesce(.data$area_control_type, .data$control_type),
        control_label = dplyr::coalesce(.data$area_control_label, .data$control_label)
      ) |>
      dplyr::select(-dplyr::all_of(c("area_control_type", "area_control_label")))
  }

  controls <- assignments |>
    dplyr::filter(!is.na(.data$control_type)) |>
    dplyr::distinct(.data$control_type, .data$control_label) |>
    dplyr::arrange(
      factor(.data$control_type, levels = c("area", "outlier")),
      .data$control_label
    )

  list(
    assignments = dplyr::arrange(assignments, .data$activity_id),
    controls = controls
  )
}

tbr_focus_area_representatives <- function(focus_areas, representatives) {
  area_controls <- focus_areas$controls |>
    dplyr::filter(.data$control_type == "area")
  if (nrow(area_controls) == 0L) {
    return(tibble::tibble(
      fallback_label = character(),
      latitude = double(),
      longitude = double()
    ))
  }

  purrr::map_dfr(area_controls$control_label, function(control_label) {
    activity_ids <- focus_areas$assignments |>
      dplyr::filter(
        .data$control_type == "area",
        .data$control_label == .env$control_label
      ) |>
      dplyr::pull(.data$activity_id)
    members <- representatives |>
      dplyr::filter(.data$activity_id %in% activity_ids)
    if (nrow(members) == 0L) {
      return(tibble::tibble(
        fallback_label = control_label,
        latitude = NA_real_,
        longitude = NA_real_
      ))
    }
    tibble::tibble(
      fallback_label = control_label,
      latitude = round(
        stats::median(members$latitude),
        TBR_FOCUS_GEOCODE_DECIMALS
      ),
      longitude = round(
        stats::median(members$longitude),
        TBR_FOCUS_GEOCODE_DECIMALS
      )
    )
  })
}

tbr_locality_label <- function(geocoded_row, fallback_label) {
  for (field in TBR_FOCUS_LOCALITY_FIELDS) {
    if (!field %in% names(geocoded_row)) next
    value <- trimws(as.character(geocoded_row[[field]][[1]]))
    if (!is.na(value) && nzchar(value)) return(value)
  }
  fallback_label
}

disambiguate_tbr_locality_labels <- function(labels) {
  totals <- table(labels)
  occurrences <- ave(seq_along(labels), labels, FUN = seq_along)
  ifelse(
    as.integer(totals[labels]) > 1L,
    paste0(labels, " (", occurrences, ")"),
    labels
  )
}

label_tbr_focus_areas <- function(
  model,
  geocoder = getOption(
    "cycling_analytics_position_geocoder",
    default_position_reverse_geocoder
  ),
  cache = .position_geocode_cache,
  warn = default_position_geocode_warning
) {
  positions <- tbr_focus_area_representatives(
    model$focus_areas,
    model$representatives
  )
  if (nrow(positions) == 0L) return(model)

  geocoded <- geocode_position_extremities(
    positions,
    geocoder = geocoder,
    cache = cache,
    warn = function(...) {
      warn(
        paste(
          "TBR focus-area locality lookup failed;",
          "generic area labels will be used."
        )
      )
    }
  )
  labels <- vapply(
    seq_len(nrow(geocoded)),
    function(index) {
      tbr_locality_label(
        geocoded[index, , drop = FALSE],
        geocoded$fallback_label[[index]]
      )
    },
    character(1)
  ) |>
    disambiguate_tbr_locality_labels()
  label_map <- stats::setNames(labels, geocoded$fallback_label)

  model$focus_areas$assignments <- model$focus_areas$assignments |>
    dplyr::mutate(
      control_label = dplyr::case_when(
        !is.na(.data$control_type) &
          .data$control_type == "area" &
          .data$control_label %in% names(label_map) ~
          unname(label_map[.data$control_label]),
        TRUE ~ .data$control_label
      )
    )
  model$focus_areas$controls <- model$focus_areas$controls |>
    dplyr::mutate(
      control_label = dplyr::case_when(
        !is.na(.data$control_type) &
          .data$control_type == "area" &
          .data$control_label %in% names(label_map) ~
          unname(label_map[.data$control_label]),
        TRUE ~ .data$control_label
      )
    )
  model$viewports <- build_tbr_viewports(
    model$routes,
    model$latest_mapped_activity_id,
    model$focus_areas
  )
  model$focus_geocode <- geocoded |>
    dplyr::mutate(display_label = labels)
  model
}

tbr_route_geometry <- function(route) {
  dplyr::bind_rows(route$segments) |>
    dplyr::arrange(.data$sample_index)
}

tbr_route_representatives <- function(routes) {
  if (length(routes) == 0L) {
    return(tibble::tibble(
      activity_id = character(),
      start_datetime_local = as.POSIXct(character()),
      latitude = double(),
      longitude = double()
    ))
  }

  purrr::imap_dfr(routes, function(route, activity_id) {
    geometry <- tbr_route_geometry(route)
    first <- geometry[1, , drop = FALSE]
    tibble::tibble(
      activity_id = as.character(activity_id),
      start_datetime_local = route$activity$start_datetime_local[[1]],
      latitude = first$latitude[[1]],
      longitude = first$longitude[[1]]
    )
  })
}

tbr_geometry_bounds <- function(geometry) {
  c(
    south = min(geometry$latitude),
    west = min(geometry$longitude),
    north = max(geometry$latitude),
    east = max(geometry$longitude)
  )
}

build_tbr_viewports <- function(
  routes,
  latest_mapped_activity_id,
  focus_areas,
  latest_max_zoom = TBR_FOCUS_LATEST_MAX_ZOOM,
  area_max_zoom = TBR_FOCUS_AREA_MAX_ZOOM,
  all_max_zoom = TBR_FOCUS_ALL_MAX_ZOOM
) {
  if (length(routes) == 0L) {
    return(tibble::tibble(
      key = character(), label = character(), kind = character(),
      south = double(), west = double(), north = double(), east = double(),
      max_zoom = integer()
    ))
  }

  latest_id <- as.character(latest_mapped_activity_id)
  latest_bounds <- tbr_geometry_bounds(tbr_route_geometry(routes[[latest_id]]))
  rows <- list(tibble::tibble(
    key = "latest",
    label = "Latest",
    kind = "latest",
    south = latest_bounds[["south"]],
    west = latest_bounds[["west"]],
    north = latest_bounds[["north"]],
    east = latest_bounds[["east"]],
    max_zoom = as.integer(latest_max_zoom)
  ))

  for (control_index in seq_len(nrow(focus_areas$controls))) {
    control <- focus_areas$controls[control_index, , drop = FALSE]
    activity_ids <- focus_areas$assignments |>
      dplyr::filter(
        .data$control_type == control$control_type[[1]],
        .data$control_label == control$control_label[[1]]
      ) |>
      dplyr::pull(.data$activity_id)
    geometry <- dplyr::bind_rows(lapply(routes[activity_ids], tbr_route_geometry))
    bounds <- tbr_geometry_bounds(geometry)
    rows[[length(rows) + 1L]] <- tibble::tibble(
      key = paste0(control$control_type[[1]], "-", control_index),
      label = control$control_label[[1]],
      kind = control$control_type[[1]],
      south = bounds[["south"]],
      west = bounds[["west"]],
      north = bounds[["north"]],
      east = bounds[["east"]],
      max_zoom = as.integer(area_max_zoom)
    )
  }

  all_geometry <- dplyr::bind_rows(lapply(routes, tbr_route_geometry))
  all_bounds <- tbr_geometry_bounds(all_geometry)
  rows[[length(rows) + 1L]] <- tibble::tibble(
    key = "all",
    label = "All adventures",
    kind = "all",
    south = all_bounds[["south"]],
    west = all_bounds[["west"]],
    north = all_bounds[["north"]],
    east = all_bounds[["east"]],
    max_zoom = as.integer(all_max_zoom)
  )
  dplyr::bind_rows(rows)
}

tbr_focus_control_javascript <- function() {
  paste(
    "function(el, x, data) {",
    "  var map = this;",
    "  var views = data.viewports || [];",
    "  function applyView(view, animate) {",
    "    map.invalidateSize();",
    "    map.fitBounds([[view.south, view.west], [view.north, view.east]], {",
    "      padding: [data.padding, data.padding],",
    "      maxZoom: view.max_zoom,",
    "      animate: animate",
    "    });",
    "  }",
    "  var FocusControl = L.Control.extend({",
    "    options: { position: 'topleft' },",
    "    onAdd: function() {",
    "      var container = L.DomUtil.create('div', 'leaflet-bar tbr-focus-control');",
    "      container.setAttribute('aria-label', 'Map views');",
    "      var buttons = [];",
    "      views.forEach(function(view, index) {",
    "        var button = L.DomUtil.create('button', 'tbr-focus-button', container);",
    "        button.type = 'button';",
    "        button.textContent = view.label;",
    "        button.setAttribute('aria-label', 'Show ' + view.label);",
    "        button.setAttribute('aria-pressed', index === 0 ? 'true' : 'false');",
    "        if (index === 0) { button.classList.add('is-active'); }",
    "        buttons.push(button);",
    "        L.DomEvent.on(button, 'click', function(event) {",
    "          L.DomEvent.preventDefault(event);",
    "          L.DomEvent.stopPropagation(event);",
    "          buttons.forEach(function(candidate) {",
    "            candidate.classList.remove('is-active');",
    "            candidate.setAttribute('aria-pressed', 'false');",
    "          });",
    "          button.classList.add('is-active');",
    "          button.setAttribute('aria-pressed', 'true');",
    "          applyView(view, true);",
    "        });",
    "      });",
    "      L.DomEvent.disableClickPropagation(container);",
    "      L.DomEvent.disableScrollPropagation(container);",
    "      return container;",
    "    }",
    "  });",
    "  map.addControl(new FocusControl());",
    "  if (views.length) {",
    "    window.setTimeout(function() { applyView(views[0], false); }, 250);",
    "  }",
    "  if (window.jQuery) {",
    "    window.jQuery(document).on('shown.bs.tab.tbrFocus-' + el.id, function() {",
    "      if (el.offsetParent !== null) {",
    "        window.setTimeout(function() { map.invalidateSize(); }, 50);",
    "      }",
    "    });",
    "  }",
    "}",
    sep = "\n"
  )
}

build_tbr_map_model <- function(activities, streams) {
  if (nrow(activities) == 0L) {
    return(list(
      routes = list(),
      latest_mapped_activity_id = NA_character_,
      unmapped = 0L,
      representatives = tbr_route_representatives(list()),
      focus_areas = discover_tbr_focus_areas(tbr_route_representatives(list())),
      viewports = build_tbr_viewports(list(), NA_character_, list())
    ))
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
  latest_mapped_activity_id <- if (length(mapped_ids)) tail(mapped_ids, 1) else NA_character_
  representatives <- tbr_route_representatives(routes)
  focus_areas <- discover_tbr_focus_areas(
    representatives,
    latest_mapped_activity_id = latest_mapped_activity_id
  )
  list(
    routes = routes,
    latest_mapped_activity_id = latest_mapped_activity_id,
    unmapped = nrow(ordered) - length(mapped_ids),
    representatives = representatives,
    focus_areas = focus_areas,
    viewports = build_tbr_viewports(
      routes,
      latest_mapped_activity_id,
      focus_areas
    )
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

draw_tbr_adventure_map <- function(
  activities,
  streams,
  geocode_focus_labels = TRUE,
  geocoder = getOption(
    "cycling_analytics_position_geocoder",
    default_position_reverse_geocoder
  ),
  geocode_cache = .position_geocode_cache,
  geocode_warn = default_position_geocode_warning
) {
  if (nrow(activities) == 0L) {
    return(latest_ride_notice("No family adventures are available yet."))
  }
  model <- build_tbr_map_model(activities, streams)
  if (length(model$routes) == 0L) {
    return(latest_ride_notice(
      "Our adventures are recorded, but none currently has usable route geometry."
    ))
  }
  if (isTRUE(geocode_focus_labels)) {
    model <- label_tbr_focus_areas(
      model,
      geocoder = geocoder,
      cache = geocode_cache,
      warn = geocode_warn
    )
  }

  map <- leaflet::leaflet() |>
    leaflet::addTiles(
      carto_basemap_tile_url("dark_matter"),
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
        color = if (is_latest_mapped) TBR_LATEST_ROUTE_COLOR else
          TBR_HISTORICAL_ROUTE_COLOR,
        weight = if (is_latest_mapped) TBR_LATEST_ROUTE_WEIGHT else
          TBR_HISTORICAL_ROUTE_WEIGHT,
        opacity = if (is_latest_mapped) TBR_LATEST_ROUTE_OPACITY else
          TBR_HISTORICAL_ROUTE_OPACITY,
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
  map <- leaflet::addControl(
    map,
    html = label,
    position = "topright",
    className = "tbr-map-status"
  )
  viewport_data <- lapply(seq_len(nrow(model$viewports)), function(index) {
    as.list(model$viewports[index, , drop = FALSE])
  })
  htmlwidgets::onRender(
    map,
    tbr_focus_control_javascript(),
    data = list(
      viewports = viewport_data,
      padding = TBR_FOCUS_VIEWPORT_PADDING_PX
    )
  )
}
