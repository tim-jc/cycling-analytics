INSPECTOR_STREAM_COLUMNS <- c(
  "activity_id", "sample_index", "time_seconds", "distance_metres",
  "latitude", "longitude", "altitude_metres",
  "velocity_smooth_metres_per_second", "heartrate_bpm", "cadence_rpm",
  "watts", "temperature_celsius", "is_moving", "grade_smooth_percent",
  "raw_stream_count", "raw_max_original_size", "raw_stream_retrieved_at",
  "transformed_at"
)

INSPECTOR_METRICS <- tibble::tribble(
  ~column, ~label, ~unit,
  "distance_metres", "Device distance", "m",
  "altitude_metres", "Elevation", "m",
  "velocity_smooth_metres_per_second", "Speed", "m/s",
  "heartrate_bpm", "Heart rate", "bpm",
  "watts", "Power", "W",
  "cadence_rpm", "Cadence", "rpm",
  "temperature_celsius", "Temperature", "°C",
  "grade_smooth_percent", "Grade", "%"
)

empty_inspector_streams <- function() {
  result <- as.data.frame(stats::setNames(
    replicate(length(INSPECTOR_STREAM_COLUMNS), logical(), simplify = FALSE),
    INSPECTOR_STREAM_COLUMNS
  ))
  result$activity_id <- character()
  result$sample_index <- integer()
  result
}

normalise_inspector_streams <- function(streams) {
  if (nrow(streams) == 0L && length(names(streams)) == 0L) {
    return(empty_inspector_streams())
  }
  required <- c("activity_id", "sample_index")
  missing_required <- setdiff(required, names(streams))
  if (length(missing_required)) {
    stop(
      "Activity streams are missing required column(s): ",
      paste(missing_required, collapse = ", "),
      call. = FALSE
    )
  }
  if (anyNA(streams$sample_index)) {
    stop("Canonical sample indices must not be missing.", call. = FALSE)
  }
  if (anyDuplicated(streams$sample_index)) {
    stop("Canonical sample indices must be unique within an activity.", call. = FALSE)
  }

  for (column in setdiff(INSPECTOR_STREAM_COLUMNS, names(streams))) {
    streams[[column]] <- NA
  }
  streams |>
    dplyr::select(dplyr::all_of(INSPECTOR_STREAM_COLUMNS)) |>
    dplyr::arrange(.data$sample_index)
}

inspector_coordinate_is_valid <- function(latitude, longitude) {
  is.finite(latitude) & is.finite(longitude) &
    latitude >= -90 & latitude <= 90 &
    longitude >= -180 & longitude <= 180
}

prepare_inspector_route <- function(streams) {
  streams <- normalise_inspector_streams(streams)
  if (nrow(streams) == 0L) {
    return(list(points = streams, segments = list()))
  }

  valid <- inspector_coordinate_is_valid(streams$latitude, streams$longitude)
  index_gap <- c(FALSE, diff(streams$sample_index) != 1L)
  segment_break <- !valid | index_gap | c(FALSE, !valid[-length(valid)])
  segment_id <- cumsum(segment_break)
  points <- streams |>
    dplyr::mutate(
      coordinate_valid = valid,
      route_segment = segment_id
    ) |>
    dplyr::filter(.data$coordinate_valid)
  segments <- split(points, points$route_segment)
  segments <- unname(segments[vapply(segments, nrow, integer(1)) >= 2L])
  list(points = points, segments = segments)
}

inspector_available_metrics <- function(streams) {
  streams <- normalise_inspector_streams(streams)
  available <- vapply(
    INSPECTOR_METRICS$column,
    function(column) any(!is.na(streams[[column]])),
    logical(1)
  )
  INSPECTOR_METRICS[available, , drop = FALSE]
}

prepare_inspection_model <- function(activity, streams) {
  if (nrow(activity) > 1L) {
    stop("Activity lookup returned more than one row.", call. = FALSE)
  }
  streams <- normalise_inspector_streams(streams)
  if (nrow(activity) == 1L && nrow(streams) > 0L &&
      any(as.character(streams$activity_id) != as.character(activity$activity_id[[1]]))) {
    stop("Stream rows do not all belong to the selected activity.", call. = FALSE)
  }
  list(
    activity = activity,
    streams = streams,
    route = prepare_inspector_route(streams),
    metrics = inspector_available_metrics(streams)
  )
}

inspector_sample <- function(model, sample_index) {
  if (is.null(sample_index) || length(sample_index) != 1L || is.na(sample_index)) {
    return(model$streams[0, , drop = FALSE])
  }
  model$streams[model$streams$sample_index == as.integer(sample_index), , drop = FALSE]
}

resolve_inspector_sample_index <- function(model, sample_index) {
  value <- suppressWarnings(as.integer(sample_index))
  if (length(value) != 1L || is.na(value) ||
      !value %in% model$streams$sample_index) {
    stop("Boundary must be an existing canonical sample index.", call. = FALSE)
  }
  value
}

inspector_neighbour_index <- function(model, sample_index, direction) {
  sample_index <- resolve_inspector_sample_index(model, sample_index)
  direction <- match.arg(direction, c("previous", "next"))
  indexes <- model$streams$sample_index
  position <- match(sample_index, indexes)
  target <- position + if (direction == "previous") -1L else 1L
  if (target < 1L || target > length(indexes)) sample_index else indexes[[target]]
}

validate_inspector_range <- function(model, start_index, end_index) {
  start_index <- resolve_inspector_sample_index(model, start_index)
  end_index <- resolve_inspector_sample_index(model, end_index)
  if (start_index > end_index) {
    stop("Start sample index must not exceed end sample index.", call. = FALSE)
  }
  c(start = start_index, end = end_index)
}

inspector_range_streams <- function(model, start_index, end_index) {
  range <- validate_inspector_range(model, start_index, end_index)
  model$streams |>
    dplyr::filter(
      .data$sample_index >= range[["start"]],
      .data$sample_index <= range[["end"]]
    )
}

inspector_clipboard_text <- function(model, start_index, end_index) {
  range <- validate_inspector_range(model, start_index, end_index)
  paste0(
    "ride_start_sample_index = ", range[["start"]], "\n",
    "ride_end_sample_index = ", range[["end"]]
  )
}

inspector_haversine_metres <- function(latitude, longitude, target_latitude, target_longitude) {
  radius <- 6371008.8
  radians <- pi / 180
  lat1 <- latitude * radians
  lat2 <- target_latitude * radians
  lat_delta <- (target_latitude - latitude) * radians
  lon_delta <- (target_longitude - longitude) * radians
  a <- sin(lat_delta / 2)^2 + cos(lat1) * cos(lat2) * sin(lon_delta / 2)^2
  2 * radius * atan2(sqrt(pmin(1, pmax(0, a))), sqrt(1 - pmin(1, pmax(0, a))))
}

nearest_inspector_sample <- function(model, latitude, longitude, ambiguity_metres = 5) {
  points <- model$route$points
  if (nrow(points) == 0L || !inspector_coordinate_is_valid(latitude, longitude)) {
    return(NULL)
  }
  distances <- inspector_haversine_metres(
    points$latitude,
    points$longitude,
    latitude,
    longitude
  )
  selected <- which.min(distances)
  candidates <- which(distances <= distances[[selected]] + ambiguity_metres)
  list(
    sample_index = points$sample_index[[selected]],
    distance_metres = distances[[selected]],
    ambiguous = length(candidates) > 1L,
    candidate_indices = points$sample_index[candidates]
  )
}
