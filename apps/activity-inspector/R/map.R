inspector_route_segments <- function(model, start_index = NULL, end_index = NULL) {
  if (!is.null(start_index) && !is.null(end_index)) {
    streams <- inspector_range_streams(model, start_index, end_index)
    return(prepare_inspector_route(streams)$segments)
  }
  model$route$segments
}

inspector_valid_points <- function(model, start_index = NULL, end_index = NULL) {
  streams <- if (!is.null(start_index) && !is.null(end_index)) {
    inspector_range_streams(model, start_index, end_index)
  } else {
    model$streams
  }
  streams[
    inspector_coordinate_is_valid(streams$latitude, streams$longitude),
    ,
    drop = FALSE
  ]
}

add_inspector_segments <- function(
  map,
  segments,
  group,
  color,
  weight,
  opacity
) {
  for (index in seq_along(segments)) {
    map <- leaflet::addPolylines(
      map,
      data = segments[[index]],
      lng = ~longitude,
      lat = ~latitude,
      layerId = paste0(group, "-", index),
      group = group,
      color = color,
      weight = weight,
      opacity = opacity,
      smoothFactor = 0,
      options = leaflet::pathOptions(className = paste0("inspector-", group))
    )
  }
  map
}

fit_inspector_points <- function(map, points, maximum_zoom = 15L) {
  if (nrow(points) == 0L) return(map)
  if (nrow(points) == 1L ||
      (length(unique(points$latitude)) == 1L && length(unique(points$longitude)) == 1L)) {
    return(leaflet::setView(
      map,
      lng = points$longitude[[1]],
      lat = points$latitude[[1]],
      zoom = maximum_zoom
    ))
  }
  leaflet::fitBounds(
    map,
    lng1 = min(points$longitude),
    lat1 = min(points$latitude),
    lng2 = max(points$longitude),
    lat2 = max(points$latitude),
    options = list(padding = c(20, 20), maxZoom = maximum_zoom)
  )
}

build_inspector_map <- function(model) {
  map <- leaflet::leaflet(options = leaflet::leafletOptions(preferCanvas = TRUE)) |>
    leaflet::addTiles(
      carto_basemap_tile_url("positron"),
      attribution = paste(
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors',
        '&copy; <a href="https://carto.com/attributions">CARTO</a>'
      )
    )
  map <- add_inspector_segments(
    map,
    model$route$segments,
    group = "full-route",
    color = "#607D8B",
    weight = 3,
    opacity = 0.75
  )
  fit_inspector_points(map, model$route$points)
}

update_inspector_map <- function(
  proxy,
  model,
  current_index = NULL,
  start_index = NULL,
  end_index = NULL
) {
  proxy <- proxy |>
    leaflet::clearGroup("selected-route") |>
    leaflet::clearGroup("current-sample") |>
    leaflet::clearGroup("boundaries")

  if (!is.null(start_index) && !is.null(end_index)) {
    proxy <- add_inspector_segments(
      proxy,
      inspector_route_segments(model, start_index, end_index),
      group = "selected-route",
      color = "#E76F51",
      weight = 6,
      opacity = 0.95
    )
  }

  current <- inspector_sample(model, current_index)
  if (nrow(current) == 1L &&
      inspector_coordinate_is_valid(current$latitude, current$longitude)) {
    proxy <- leaflet::addCircleMarkers(
      proxy,
      data = current,
      lng = ~longitude,
      lat = ~latitude,
      layerId = ~paste0("current-", sample_index),
      group = "current-sample",
      radius = 7,
      color = "#17324D",
      fillColor = "#FFFFFF",
      fillOpacity = 1,
      weight = 3,
      label = ~paste("Sample", sample_index)
    )
  }

  boundary_indexes <- unique(stats::na.omit(c(start_index, end_index)))
  if (length(boundary_indexes)) {
    boundaries <- model$streams |>
      dplyr::filter(.data$sample_index %in% boundary_indexes) |>
      dplyr::filter(inspector_coordinate_is_valid(.data$latitude, .data$longitude))
    same_boundary <- !is.null(start_index) && !is.null(end_index) &&
      identical(as.integer(start_index), as.integer(end_index))
    start_match <- if (is.null(start_index)) {
      rep(FALSE, nrow(boundaries))
    } else {
      boundaries$sample_index == start_index
    }
    boundaries <- boundaries |>
      dplyr::mutate(
        boundary = dplyr::case_when(
          .env$same_boundary ~ "Start and end",
          .env$start_match ~ "Start",
          TRUE ~ "End"
        ),
        boundary_color = dplyr::case_when(
          .data$boundary == "Start" ~ "#2A9D8F",
          .data$boundary == "End" ~ "#D1495B",
          TRUE ~ "#7B2CBF"
        )
      )
    if (nrow(boundaries)) {
      proxy <- leaflet::addCircleMarkers(
        proxy,
        data = boundaries,
        lng = ~longitude,
        lat = ~latitude,
        layerId = ~paste0("boundary-", sample_index),
        group = "boundaries",
        radius = 8,
        color = ~boundary_color,
        fillColor = ~boundary_color,
        fillOpacity = 1,
        weight = 2,
        label = ~paste0(boundary, ": sample ", sample_index)
      )
    }
  }
  proxy
}
