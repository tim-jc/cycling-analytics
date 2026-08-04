`%||%` <- function(left, right) if (is.null(left)) right else left

safe_mean <- function(x) {
  if (length(x) == 0L || all(is.na(x))) NA_real_ else mean(x, na.rm = TRUE)
}

safe_max <- function(x) {
  if (length(x) == 0L || all(is.na(x))) NA_real_ else max(x, na.rm = TRUE)
}

split_report_notes <- function(text) {
  if (is.null(text) || length(text) == 0L || is.na(text) || !nzchar(trimws(text))) {
    return(character())
  }
  lines <- unlist(strsplit(text, "\\r?\\n|\\s*\\|\\s*"))
  lines <- trimws(lines)
  lines[nzchar(lines)]
}

lap_stream_slice <- function(
  streams,
  start_time_seconds,
  end_time_seconds
) {
  if (nrow(streams) == 0L) return(streams[0, ])
  if (!is.finite(start_time_seconds) || !is.finite(end_time_seconds) ||
    end_time_seconds <= start_time_seconds) return(streams[0, ])

  dplyr::filter(
    streams,
    .data$time_seconds >= start_time_seconds,
    .data$time_seconds < end_time_seconds
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

lap_display_name <- function(lap_name, lap_index) {
  ifelse(
    !is.na(lap_name) & nzchar(trimws(lap_name)),
    lap_name,
    paste("Lap", lap_index)
  )
}

prepare_lap_presentation_model <- function(laps, streams, activity) {
  if (nrow(laps) == 0L) return(tibble::tibble())
  ride_average_power <- activity$average_power_watts[[1]] %||% NA_real_

  purrr::map_dfr(seq_len(nrow(laps)), function(index) {
    lap <- laps[index, ]
    start_time_seconds <- lap$start_time_seconds[[1]]
    end_time_seconds <- lap$end_time_seconds[[1]]
    samples <- lap_stream_slice(
      streams,
      start_time_seconds,
      end_time_seconds
    ) |>
      dplyr::arrange(.data$sample_index)
    observed_samples <- if (nrow(samples) == 0L) 0L else {
      sum(
        !is.na(samples$watts) |
          !is.na(samples$heartrate_bpm) |
          !is.na(samples$altitude_metres)
      )
    }
    altitude <- samples$altitude_metres[!is.na(samples$altitude_metres)]
    net_elevation <- if (length(altitude) >= 2L) {
      utils::tail(altitude, 1) - utils::head(altitude, 1)
    } else NA_real_
    start_distance <- if (nrow(samples) > 0L &&
      any(!is.na(samples$distance_metres))) {
      min(samples$distance_metres, na.rm = TRUE)
    } else NA_real_
    end_distance <- if (nrow(samples) > 0L &&
      any(!is.na(samples$distance_metres))) {
      max(samples$distance_metres, na.rm = TRUE)
    } else NA_real_
    duration <- lap$moving_time_seconds[[1]]
    elevation <- lap$elevation_gain_metres[[1]]

    tibble::tibble(
      lap_id = lap$lap_id,
      activity_id = lap$activity_id,
      lap_index = lap$lap_index,
      effort_name = lap_display_name(lap$lap_name, lap$lap_index),
      elapsed_time_seconds = lap$elapsed_time_seconds,
      moving_time_seconds = duration,
      distance_metres = lap$distance_metres,
      start_sample_index = lap$start_sample_index,
      end_sample_index = lap$end_sample_index,
      start_time_seconds = start_time_seconds,
      end_time_seconds = end_time_seconds,
      start_distance_metres = start_distance,
      end_distance_metres = end_distance,
      average_speed_miles_per_hour =
        lap$average_speed_metres_per_second * 2.236936,
      average_cadence_rpm = lap$average_cadence_rpm,
      average_power_watts = lap$average_power_watts,
      normalized_power_watts = NA_real_,
      average_heartrate_bpm = lap$average_heartrate_bpm,
      elevation_gain_metres = elevation,
      vam_metres_per_hour = dplyr::if_else(
        !is.na(elevation) & !is.na(duration) & duration > 0,
        elevation / duration * 3600,
        NA_real_
      ),
      net_elevation_change_metres = net_elevation,
      telemetry_sample_count = observed_samples,
      telemetry_available = !is.na(lap$start_sample_index) &
        !is.na(lap$end_sample_index) & observed_samples >= 60L,
      ride_average_power_watts = ride_average_power,
      power_ratio = dplyr::if_else(
        !is.na(lap$average_power_watts) & is.finite(ride_average_power) &
          ride_average_power > 0,
        lap$average_power_watts / ride_average_power,
        NA_real_
      )
    )
  })
}

identify_coaching_effort_candidates <- function(
  lap_model,
  minimum_duration_seconds = 180,
  minimum_moving_ratio = 0.75
) {
  if (nrow(lap_model) == 0L) return(lap_model)
  excluded_name <- "warm[ -]?up|cool[ -]?down|recover|recovery|rest|easy"

  lap_model |>
    dplyr::mutate(
      moving_ratio = dplyr::if_else(
        !is.na(.data$elapsed_time_seconds) & .data$elapsed_time_seconds > 0,
        .data$moving_time_seconds / .data$elapsed_time_seconds,
        NA_real_
      ),
      excluded_by_name = grepl(
        excluded_name,
        .data$effort_name,
        ignore.case = TRUE
      )
    ) |>
    dplyr::filter(
      !is.na(.data$moving_time_seconds),
      .data$moving_time_seconds >= minimum_duration_seconds,
      is.na(.data$moving_ratio) | .data$moving_ratio >= minimum_moving_ratio,
      !.data$excluded_by_name,
      .data$telemetry_available
    )
}

rank_coaching_effort_candidates <- function(candidates) {
  if (nrow(candidates) == 0L) return(candidates)

  candidates |>
    dplyr::mutate(
      power_signal = !is.na(.data$power_ratio) & (
        .data$power_ratio >= 1.12 |
          (.data$moving_time_seconds >= 900 & .data$power_ratio >= 1.07)
      ),
      climb_signal = !is.na(.data$elevation_gain_metres) &
        .data$elevation_gain_metres >= 75 &
        !is.na(.data$vam_metres_per_hour) &
        .data$vam_metres_per_hour >= 300,
      descent_without_power = !is.na(.data$net_elevation_change_metres) &
        .data$net_elevation_change_metres <= -50 & !.data$power_signal,
      power_score = dplyr::if_else(
        !is.na(.data$power_ratio),
        pmin(pmax((.data$power_ratio - 1) * 8, 0), 3),
        0
      ),
      climb_score = dplyr::if_else(
        .data$climb_signal,
        pmin(.data$elevation_gain_metres / 200, 2) +
          pmin(.data$vam_metres_per_hour / 800, 1),
        0
      ),
      sustained_score = dplyr::if_else(
        .data$power_signal | .data$climb_signal,
        pmin(log1p(.data$moving_time_seconds / 600) / 2, 1),
        0
      ),
      significance_score = .data$power_score + .data$climb_score +
        .data$sustained_score
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$significance_score),
      dplyr::desc(.data$moving_time_seconds),
      .data$lap_index
    )
}

apply_coaching_effort_significance <- function(
  ranked_candidates,
  significance_threshold = 1.5
) {
  if (nrow(ranked_candidates) == 0L) return(ranked_candidates)
  ranked_candidates |>
    dplyr::filter(
      (.data$power_signal | .data$climb_signal),
      !.data$descent_without_power,
      .data$significance_score >= significance_threshold
    )
}

select_coaching_efforts <- function(
  lap_model,
  maximum_efforts = 5L,
  significance_threshold = 1.5
) {
  candidates <- identify_coaching_effort_candidates(lap_model) |>
    rank_coaching_effort_candidates() |>
    apply_coaching_effort_significance(significance_threshold)
  if (nrow(candidates) == 0L) return(candidates)

  metric_winner <- function(data, column, filter_column = NULL) {
    eligible <- data
    if (!is.null(filter_column)) {
      eligible <- eligible |> dplyr::filter(.data[[filter_column]])
    }
    eligible <- eligible |> dplyr::filter(!is.na(.data[[column]]))
    if (nrow(eligible) == 0L) return(character())
    as.character(
      eligible |>
        dplyr::slice_max(.data[[column]], n = 1, with_ties = FALSE) |>
        dplyr::pull(.data$lap_id)
    )
  }

  winner_ids <- unique(c(
    metric_winner(candidates, "average_power_watts", "power_signal"),
    metric_winner(candidates, "moving_time_seconds", "power_signal"),
    metric_winner(candidates, "elevation_gain_metres", "climb_signal"),
    metric_winner(candidates, "vam_metres_per_hour", "climb_signal")
  ))
  ranked_ids <- as.character(candidates$lap_id)
  selected_ids <- utils::head(unique(c(winner_ids, ranked_ids)), maximum_efforts)

  candidates |>
    dplyr::filter(as.character(.data$lap_id) %in% selected_ids) |>
    dplyr::arrange(.data$lap_index)
}

prepare_coaching_effort_presentation <- function(selected_efforts) {
  if (nrow(selected_efforts) == 0L) return(selected_efforts)

  selected_efforts |>
    dplyr::arrange(.data$lap_index) |>
    dplyr::mutate(
      coaching_effort_number = dplyr::row_number(),
      source_lap_name = .data$effort_name,
      coaching_effort_name = paste0(
        "Interval ",
        .data$coaching_effort_number,
        " (",
        .data$source_lap_name,
        ")"
      )
    )
}

summarise_recovery_intervals <- function(lap_model, selected_efforts) {
  if (nrow(selected_efforts) < 2L || nrow(lap_model) == 0L) {
    return(tibble::tibble())
  }

  selected <- selected_efforts |>
    dplyr::arrange(.data$lap_index)

  purrr::map_dfr(seq_len(nrow(selected) - 1L), function(index) {
    recovery_laps <- lap_model |>
      dplyr::filter(
        .data$lap_index > selected$lap_index[[index]],
        .data$lap_index < selected$lap_index[[index + 1L]]
      )
    if (nrow(recovery_laps) == 0L) return(tibble::tibble())

    duration <- sum(recovery_laps$moving_time_seconds, na.rm = TRUE)
    valid_power <- !is.na(recovery_laps$average_power_watts) &
      !is.na(recovery_laps$moving_time_seconds)
    average_power <- if (duration > 0 && any(valid_power)) {
      stats::weighted.mean(
        recovery_laps$average_power_watts[valid_power],
        recovery_laps$moving_time_seconds[valid_power],
        na.rm = TRUE
      )
    } else NA_real_

    tibble::tibble(
      recovery_number = index,
      recovery_name = paste0("R", index),
      source_laps = paste(recovery_laps$effort_name, collapse = ", "),
      moving_time_seconds = duration,
      average_power_watts = average_power
    )
  })
}

build_coaching_effort_model <- function(effort, streams) {
  samples <- lap_stream_slice(
    streams,
    effort$start_time_seconds[[1]],
    effort$end_time_seconds[[1]]
  ) |>
    dplyr::arrange(.data$sample_index)
  if (nrow(samples) > 0L) {
    start_time <- min(samples$time_seconds, na.rm = TRUE)
    start_distance <- if (any(!is.na(samples$distance_metres))) {
      min(samples$distance_metres, na.rm = TRUE)
    } else NA_real_
    samples <- samples |>
      dplyr::mutate(
        effort_time_minutes = (.data$time_seconds - start_time) / 60,
        effort_distance_miles = (.data$distance_metres - start_distance) *
          0.000621371
      )
  }
  list(summary = effort, streams = samples)
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
