build_inspector_timeline <- function(
  model,
  metric,
  current_index = NULL,
  start_index = NULL,
  end_index = NULL
) {
  metric_row <- model$metrics[model$metrics$column == metric, , drop = FALSE]
  if (nrow(metric_row) != 1L) {
    return(plotly::plot_ly() |>
      plotly::layout(annotations = list(list(
        text = "No plottable stream metric is available.",
        showarrow = FALSE
      ))))
  }

  data <- model$streams
  plot <- plotly::plot_ly(
    data = data,
    x = ~sample_index,
    y = data[[metric]],
    customdata = ~sample_index,
    type = "scattergl",
    mode = "lines",
    source = "inspector_timeline",
    line = list(color = "#3D627D", width = 1.4),
    hovertemplate = paste0(
      "Sample %{customdata}<br>", metric_row$label[[1]],
      ": %{y:.2f} ", metric_row$unit[[1]], "<extra></extra>"
    )
  )

  shapes <- list()
  if (!is.null(start_index) && !is.null(end_index)) {
    shapes[[length(shapes) + 1L]] <- list(
      type = "rect", xref = "x", yref = "paper",
      x0 = start_index, x1 = end_index, y0 = 0, y1 = 1,
      fillcolor = "rgba(231,111,81,0.13)", line = list(width = 0)
    )
  }
  if (!is.null(current_index)) {
    shapes[[length(shapes) + 1L]] <- list(
      type = "line", xref = "x", yref = "paper",
      x0 = current_index, x1 = current_index, y0 = 0, y1 = 1,
      line = list(color = "#17324D", width = 2)
    )
  }

  plot |>
    plotly::layout(
      xaxis = list(title = "Canonical sample index", rangeslider = list(visible = TRUE)),
      yaxis = list(title = paste0(metric_row$label[[1]], " (", metric_row$unit[[1]], ")")),
      dragmode = "zoom",
      hovermode = "closest",
      shapes = shapes,
      margin = list(l = 65, r = 20, t = 15, b = 55)
    ) |>
    plotly::config(displaylogo = FALSE, scrollZoom = TRUE)
}
