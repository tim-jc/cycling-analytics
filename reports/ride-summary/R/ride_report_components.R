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
