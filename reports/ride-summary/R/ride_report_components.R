report_colours <- list(
  ink = "#243447",
  muted = "#66788A",
  grid = "#DCE3E8",
  fill = "#BFD7E5",
  accent = "#D86D3B",
  elevation = "#78996A",
  heart = "#B94A48"
)

ride_report_theme <- function() {
  ggplot2::theme_minimal(base_size = 9) +
    ggplot2::theme(
      text = ggplot2::element_text(colour = report_colours$ink),
      plot.title = ggplot2::element_text(
        face = "bold", size = 11, margin = ggplot2::margin(b = 5)
      ),
      axis.title = ggplot2::element_text(size = 8),
      axis.text = ggplot2::element_text(size = 7),
      panel.grid.minor = ggplot2::element_blank(),
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(
        colour = report_colours$grid, linewidth = 0.25
      ),
      plot.margin = ggplot2::margin(4, 4, 4, 4)
    )
}

format_duration <- function(seconds) {
  if (!is.finite(seconds)) return("-")
  seconds <- round(seconds)
  hours <- seconds %/% 3600
  minutes <- (seconds %% 3600) %/% 60
  remaining <- seconds %% 60
  if (hours > 0) {
    sprintf("%d:%02d:%02d", hours, minutes, remaining)
  } else {
    sprintf("%d:%02d", minutes, remaining)
  }
}

format_metric <- function(value, suffix = "", digits = 0) {
  if (length(value) == 0L || !is.finite(value)) return("-")
  paste0(format(round(value, digits), nsmall = digits, trim = TRUE), suffix)
}

summary_cards <- function(values, pairs_per_row = 2L) {
  labels <- names(values)
  values <- as.character(unlist(values, use.names = FALSE))
  cell_count <- length(labels)
  row_count <- ceiling(cell_count / pairs_per_row)
  padded_count <- row_count * pairs_per_row
  labels <- c(labels, rep("", padded_count - cell_count))
  values <- c(values, rep("", padded_count - cell_count))

  grid <- purrr::map_dfc(seq_len(pairs_per_row), function(pair_index) {
    indices <- seq(pair_index, padded_count, by = pairs_per_row)
    tibble::tibble(
      metric = ifelse(
        nzchar(labels[indices]),
        paste0("**", labels[indices], "**"),
        ""
      ),
      value = values[indices]
    )
  })

  table_markdown <- as.character(knitr::kable(
    grid,
    format = "pipe",
    col.names = rep(c("Metric", "Value"), pairs_per_row),
    align = rep(c("l", "l"), pairs_per_row),
    row.names = FALSE
  ))
  cat(
    "\n\n",
    paste(table_markdown, collapse = "\n"),
    "\n\n",
    sep = ""
  )
}

compact_table <- function(data, align = NULL) {
  knitr::kable(data, format = "pipe", align = align, row.names = FALSE)
}

plot_ride_metric <- function(
  streams,
  value_column,
  title,
  y_label,
  colour,
  fill = NULL,
  highlighted_efforts = tibble::tibble()
) {
  if (nrow(streams) == 0L || all(is.na(streams[[value_column]]))) return(NULL)
  plot_data <- streams |>
    dplyr::mutate(
      distance_miles = distance_metres * 0.000621371,
      value = .data[[value_column]]
    )
  plot <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = distance_miles, y = value)
  )
  if (nrow(highlighted_efforts) > 0L) {
    highlight_data <- highlighted_efforts |>
      dplyr::transmute(
        xmin = start_distance_metres * 0.000621371,
        xmax = end_distance_metres * 0.000621371
      )
    plot <- plot +
      ggplot2::geom_rect(
        data = highlight_data,
        ggplot2::aes(
          xmin = xmin,
          xmax = xmax,
          ymin = -Inf,
          ymax = Inf
        ),
        inherit.aes = FALSE,
        fill = report_colours$accent,
        alpha = 0.10
      )
  }
  if (!is.null(fill)) {
    plot <- plot +
      ggplot2::geom_area(fill = fill, alpha = 0.65, na.rm = TRUE)
  }
  plot +
    ggplot2::geom_line(colour = colour, linewidth = 0.35, na.rm = TRUE) +
    ggplot2::labs(title = title, x = "Distance (mi)", y = y_label) +
    ride_report_theme()
}

plot_power_zones <- function(zone_data) {
  if (nrow(zone_data) == 0L) return(NULL)
  ggplot2::ggplot(zone_data, ggplot2::aes(x = zone, y = minutes)) +
    ggplot2::geom_col(
      fill = report_colours$fill,
      colour = report_colours$ink,
      linewidth = 0.4,
      width = 0.72
    ) +
    ggplot2::labs(
      title = "Time in power zones", x = NULL, y = "Minutes"
    ) +
    ride_report_theme()
}

plot_ride_power_curve <- function(best_efforts) {
  if (nrow(best_efforts) == 0L) return(NULL)
  ggplot2::ggplot(
    best_efforts,
    ggplot2::aes(x = duration_seconds, y = peak_value)
  ) +
    ggplot2::geom_line(colour = report_colours$ink, linewidth = 0.55) +
    ggplot2::geom_point(
      fill = report_colours$fill,
      colour = report_colours$ink,
      shape = 21,
      size = 2
    ) +
    ggplot2::scale_x_log10(
      breaks = c(5, 60, 300, 1200, 3600),
      labels = c("5 s", "1 min", "5 min", "20 min", "60 min")
    ) +
    ggplot2::labs(
      title = "Ride-only power duration curve",
      x = "Duration",
      y = "Power (W)"
    ) +
    ride_report_theme()
}

plot_effort_traces <- function(effort_streams, effort_name) {
  if (nrow(effort_streams) == 0L) return(NULL)
  effort_duration_minutes <- max(
    effort_streams$relative_time_minutes[effort_streams$is_effort],
    na.rm = TRUE
  )
  highlight <- tibble::tibble(
    xmin = 0,
    xmax = effort_duration_minutes,
    ymin = -Inf,
    ymax = Inf
  )
  power <- ggplot2::ggplot(
    effort_streams,
    ggplot2::aes(relative_time_minutes, watts)
  ) +
    ggplot2::geom_rect(
      data = highlight,
      ggplot2::aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax),
      inherit.aes = FALSE,
      fill = report_colours$accent,
      alpha = 0.10
    ) +
    ggplot2::geom_line(
      colour = report_colours$ink, linewidth = 0.4, na.rm = TRUE
    ) +
    ggplot2::labs(
      title = paste(effort_name, "- power"),
      x = NULL,
      y = "Power (W)"
    ) +
    ride_report_theme()
  elevation <- ggplot2::ggplot(
    effort_streams,
    ggplot2::aes(relative_time_minutes, altitude_metres)
  ) +
    ggplot2::geom_rect(
      data = highlight,
      ggplot2::aes(xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax),
      inherit.aes = FALSE,
      fill = report_colours$accent,
      alpha = 0.08
    ) +
    ggplot2::geom_area(
      fill = "#D7E3D2",
      colour = report_colours$elevation,
      linewidth = 0.35,
      na.rm = TRUE
    ) +
    ggplot2::labs(
      title = "Elevation",
      x = "Time from effort start (min)",
      y = "Elevation (m)"
    ) +
    ride_report_theme()
  list(power = power, elevation = elevation)
}

format_lap_summary_table <- function(lap_model) {
  if (nrow(lap_model) == 0L) return(tibble::tibble())
  lap_model |>
    dplyr::transmute(
      Lap = .data$effort_name,
      Distance = purrr::map_chr(
        .data$distance_metres * 0.000621371,
        format_metric,
        suffix = " mi",
        digits = 1
      ),
      Time = purrr::map_chr(.data$moving_time_seconds, format_duration),
      `Avg power` = purrr::map_chr(
        .data$average_power_watts,
        format_metric,
        suffix = " W"
      ),
      NP = purrr::map_chr(
        .data$normalized_power_watts,
        format_metric,
        suffix = " W"
      ),
      `Avg HR` = purrr::map_chr(
        .data$average_heartrate_bpm,
        format_metric,
        suffix = " bpm"
      ),
      Cadence = purrr::map_chr(
        .data$average_cadence_rpm,
        format_metric,
        suffix = " rpm"
      ),
      Speed = purrr::map_chr(
        .data$average_speed_miles_per_hour,
        format_metric,
        suffix = " mph",
        digits = 1
      ),
      Gain = purrr::map_chr(
        .data$elevation_gain_metres,
        format_metric,
        suffix = " m"
      )
    )
}

format_coaching_effort_summary_table <- function(selected_efforts) {
  if (nrow(selected_efforts) == 0L) return(tibble::tibble())

  selected_efforts |>
    dplyr::transmute(
      Interval = paste0(
        .data$coaching_effort_number,
        " (",
        .data$source_lap_name,
        ")"
      ),
      Power = purrr::map_chr(
        .data$average_power_watts,
        format_metric,
        suffix = " W"
      ),
      Duration = purrr::map_chr(.data$moving_time_seconds, format_duration),
      Cadence = purrr::map_chr(
        .data$average_cadence_rpm,
        format_metric,
        suffix = " rpm"
      ),
      VAM = purrr::map_chr(
        .data$vam_metres_per_hour,
        format_metric,
        suffix = " m/h"
      )
    )
}

format_recovery_summary_table <- function(recovery_intervals) {
  if (nrow(recovery_intervals) == 0L) return(tibble::tibble())

  recovery_intervals |>
    dplyr::transmute(
      Recovery = .data$recovery_name,
      Duration = purrr::map_chr(.data$moving_time_seconds, format_duration),
      `Average power` = purrr::map_chr(
        .data$average_power_watts,
        format_metric,
        suffix = " W"
      )
    )
}

plot_coaching_effort_metric <- function(
  effort_streams,
  value_column,
  title,
  y_label,
  colour,
  fill = NULL
) {
  if (nrow(effort_streams) == 0L ||
    !value_column %in% names(effort_streams) ||
    all(is.na(effort_streams[[value_column]]))) return(NULL)

  plot <- ggplot2::ggplot(
    effort_streams,
    ggplot2::aes(x = effort_time_minutes, y = .data[[value_column]])
  )
  if (!is.null(fill)) {
    value_range <- range(effort_streams[[value_column]], na.rm = TRUE)
    baseline <- value_range[[1]] - max(diff(value_range) * 0.08, 2)
    plot_data <- effort_streams |>
      dplyr::mutate(plot_baseline = baseline)
    plot <- ggplot2::ggplot(
      plot_data,
      ggplot2::aes(x = effort_time_minutes, y = .data[[value_column]])
    ) + ggplot2::geom_ribbon(
      ggplot2::aes(
        ymin = .data$plot_baseline,
        ymax = .data[[value_column]]
      ),
      fill = fill,
      colour = colour,
      linewidth = 0.3,
      alpha = 0.65,
      na.rm = TRUE
    )
  } else {
    plot <- plot + ggplot2::geom_line(
      colour = colour,
      linewidth = 0.4,
      na.rm = TRUE
    )
  }
  plot +
    ggplot2::labs(title = title, x = "Time in lap (min)", y = y_label) +
    ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(0.02, 0.08))) +
    ride_report_theme()
}

plot_coaching_effort_traces <- function(effort_streams) {
  plots <- list(
    power = plot_coaching_effort_metric(
      effort_streams,
      "watts",
      "Power",
      "Power (W)",
      report_colours$ink
    ),
    heart_rate = plot_coaching_effort_metric(
      effort_streams,
      "heartrate_bpm",
      "Heart rate",
      "Heart rate (bpm)",
      report_colours$heart
    ),
    elevation = plot_coaching_effort_metric(
      effort_streams,
      "altitude_metres",
      "Elevation",
      "Elevation (m)",
      report_colours$elevation,
      "#D7E3D2"
    )
  )
  plots[!vapply(plots, is.null, logical(1))]
}

draw_coaching_effort_traces <- function(plots) {
  if (length(plots) == 0L) return(invisible(NULL))

  grid::grid.newpage()
  grid::pushViewport(grid::viewport(
    layout = grid::grid.layout(length(plots), 1L)
  ))
  on.exit(grid::popViewport(), add = TRUE)
  for (index in seq_along(plots)) {
    print(
      plots[[index]],
      newpage = FALSE,
      vp = grid::viewport(layout.pos.row = index, layout.pos.col = 1L)
    )
  }
  invisible(NULL)
}

render_coaching_effort_page <- function(effort, streams) {
  effort_model <- build_coaching_effort_model(effort, streams)
  effort_summary <- effort_model$summary
  effort_plots <- plot_coaching_effort_traces(effort_model$streams)

  cat(
    "## ",
    effort_summary$coaching_effort_name[[1]],
    "\n\n",
    sep = ""
  )
  summary_cards(list(
    Distance = format_metric(
      effort_summary$distance_metres * 0.000621371,
      " mi",
      1
    ),
    Duration = format_duration(effort_summary$moving_time_seconds),
    `Elevation gain` = format_metric(
      effort_summary$elevation_gain_metres,
      " m"
    ),
    `Average power` = format_metric(
      effort_summary$average_power_watts,
      " W"
    ),
    `Normalized Power` = format_metric(
      effort_summary$normalized_power_watts,
      " W"
    ),
    `Average HR` = format_metric(
      effort_summary$average_heartrate_bpm,
      " bpm"
    ),
    `Average cadence` = format_metric(
      effort_summary$average_cadence_rpm,
      " rpm"
    ),
    `Average speed` = format_metric(
      effort_summary$average_speed_miles_per_hour,
      " mph",
      1
    ),
    VAM = format_metric(effort_summary$vam_metres_per_hour, " m/h")
  ), pairs_per_row = 3L)
  cat("\n\n")

  if (length(effort_plots) == 0L) {
    cat("Telemetry is unavailable for this lap.\n\n")
  } else {
    draw_coaching_effort_traces(effort_plots)
  }
}
