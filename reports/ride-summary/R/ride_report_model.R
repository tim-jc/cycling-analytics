`%||%` <- function(left, right) if (is.null(left)) right else left

safe_mean <- function(x) {
  if (length(x) == 0L || all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}

safe_max <- function(x) {
  if (length(x) == 0L || all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
}

stream_slice <- function(streams, start_index, end_index) {
  if (nrow(streams) == 0L || is.na(start_index) || is.na(end_index)) {
    return(streams[0, ])
  }
  dplyr::filter(
    streams,
    sample_index >= start_index,
    sample_index <= end_index
  )
}

filter_continuous_efforts <- function(
  best_efforts,
  absolute_tolerance_seconds = 2,
  relative_tolerance = 0.02
) {
  if (nrow(best_efforts) == 0L) return(best_efforts)

  best_efforts |>
    dplyr::mutate(
      elapsed_span_seconds = end_time_seconds - start_time_seconds,
      maximum_continuous_span = duration_seconds *
        (1 + relative_tolerance) +
        absolute_tolerance_seconds,
      is_continuous = !is.na(elapsed_span_seconds) &
        elapsed_span_seconds >= 0 &
        elapsed_span_seconds <= maximum_continuous_span
    ) |>
    dplyr::filter(is_continuous)
}

select_coaching_efforts <- function(
  best_efforts,
  desired_durations = 1200L
) {
  if (nrow(best_efforts) == 0L) return(tibble::tibble())
  best_efforts |>
    dplyr::filter(duration_seconds %in% desired_durations) |>
    dplyr::mutate(
      effort_name = paste0("Best ", duration_seconds / 60, " min power")
    )
}

build_effort_summary <- function(effort, streams) {
  samples <- stream_slice(
    streams,
    effort$start_sample_index[[1]],
    effort$end_sample_index[[1]]
  )
  altitude_change <- diff(samples$altitude_metres)
  elevation_gain <- if (length(altitude_change) == 0L ||
    all(is.na(altitude_change))) NA_real_ else {
    sum(pmax(altitude_change, 0), na.rm = TRUE)
  }
  duration <- effort$duration_seconds[[1]]
  effort_start_time <- effort$start_time_seconds[[1]]
  effort_end_time <- effort$end_time_seconds[[1]]
  context_samples <- streams |>
    dplyr::filter(
      time_seconds >= effort_start_time - 30,
      time_seconds <= effort_end_time + 30
    ) |>
    dplyr::mutate(
      relative_time_minutes = (time_seconds - effort_start_time) / 60,
      is_effort = time_seconds >= effort_start_time &
        time_seconds <= effort_end_time
    )

  list(
    streams = samples,
    context_streams = context_samples,
    summary = tibble::tibble(
      name = effort$effort_name[[1]],
      distance_miles = (
        effort$end_distance_metres[[1]] -
          effort$start_distance_metres[[1]]
      ) * 0.000621371,
      duration_seconds = duration,
      average_power_watts = effort$peak_value[[1]],
      average_heartrate_bpm = safe_mean(samples$heartrate_bpm),
      average_cadence_rpm = safe_mean(samples$cadence_rpm),
      elevation_gain_metres = elevation_gain,
      vam_metres_per_hour = if (is.finite(elevation_gain) &&
        is.finite(duration) && duration > 0) {
        elevation_gain / duration * 3600
      } else NA_real_
    )
  )
}

build_power_zones <- function(streams, ftp_watts = NA_real_) {
  if (nrow(streams) == 0L || !is.finite(ftp_watts) || ftp_watts <= 0 ||
    all(is.na(streams$watts))) return(tibble::tibble())
  streams |>
    dplyr::filter(!is.na(watts)) |>
    dplyr::mutate(zone = cut(
      watts / ftp_watts,
      breaks = c(-Inf, 0.55, 0.75, 0.90, 1.05, 1.20, Inf),
      labels = c("Z1", "Z2", "Z3", "Z4", "Z5", "Z6+")
    )) |>
    dplyr::count(zone, .drop = FALSE, name = "seconds") |>
    dplyr::mutate(minutes = seconds / 60)
}
