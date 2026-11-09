find_activity_inspector_root <- function(start = getwd()) {
  path <- normalizePath(start, winslash = "/", mustWork = TRUE)
  repeat {
    if (file.exists(file.path(path, "db", "db.R")) &&
        file.exists(file.path(path, "renv.lock"))) return(path)
    parent <- dirname(path)
    if (identical(parent, path)) break
    path <- parent
  }
  stop("Could not find the cycling-analytics project root.", call. = FALSE)
}

activity_inspector_root <- find_activity_inspector_root()
source(file.path(activity_inspector_root, "db", "db.R"))
source(file.path(activity_inspector_root, "dashboard_functions.R"))
source(file.path(activity_inspector_root, "apps", "activity-inspector", "R", "data_access.R"))
source(file.path(activity_inspector_root, "apps", "activity-inspector", "R", "inspection_model.R"))
source(file.path(activity_inspector_root, "apps", "activity-inspector", "R", "map.R"))
source(file.path(activity_inspector_root, "apps", "activity-inspector", "R", "timeline.R"))

format_inspector_duration <- function(seconds) {
  if (length(seconds) == 0L || is.na(seconds)) return("Missing")
  hours <- seconds %/% 3600
  minutes <- (seconds %% 3600) %/% 60
  secs <- seconds %% 60
  sprintf("%d:%02d:%02d", hours, minutes, secs)
}

format_inspector_value <- function(value, digits = 1L, suffix = "") {
  if (length(value) == 0L || is.na(value)) return("Missing")
  paste0(format(round(value, digits), trim = TRUE, nsmall = digits), suffix)
}

activity_inspector_ui <- shiny::fluidPage(
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  shiny::tags$head(
    shiny::includeCSS(file.path(activity_inspector_root, "apps", "activity-inspector", "www", "inspector.css")),
    shiny::tags$script(shiny::HTML(
      "Shiny.addCustomMessageHandler('copy-inspector-boundaries', function(message) {
         if (navigator.clipboard && window.isSecureContext) {
           navigator.clipboard.writeText(message.text);
         } else {
           var area = document.createElement('textarea');
           area.value = message.text;
           area.style.position = 'fixed'; area.style.opacity = '0';
           document.body.appendChild(area); area.select();
           document.execCommand('copy'); document.body.removeChild(area);
         }
       });"
    )),
    shiny::tags$script(shiny::HTML(
      "Shiny.addCustomMessageHandler('clear-inspector-number', function(message) {
         var input = document.getElementById(message.id);
         if (input) {
           input.value = '';
           input.dispatchEvent(new Event('change', {bubbles: true}));
         }
       });"
    ))
  ),
  shiny::div(
    class = "inspector-header",
    shiny::h2("Activity Inspector"),
    shiny::p("Read-only exploration of canonical Silver activity samples.")
  ),
  shiny::fluidRow(
    shiny::column(
      9,
      shiny::textInput("activity_id", "Strava activity ID", placeholder = "e.g. 5906287061")
    ),
    shiny::column(3, shiny::actionButton("load_activity", "Load activity", class = "btn-primary inspector-load"))
  ),
  shiny::uiOutput("load_status"),
  shiny::uiOutput("activity_metadata"),
  shiny::fluidRow(
    shiny::column(
      8,
      shiny::div(
        class = "inspector-card inspector-map-card",
        shiny::div(
          class = "inspector-card-heading",
          shiny::span("Route"),
          shiny::div(
            shiny::actionButton("fit_full", "Full route", class = "btn-sm btn-light"),
            shiny::actionButton("fit_selection", "Selected range", class = "btn-sm btn-light")
          )
        ),
        leaflet::leafletOutput("activity_map", height = "590px")
      )
    ),
    shiny::column(
      4,
      shiny::div(
        class = "inspector-card",
        shiny::h4("Current sample"),
        shiny::tableOutput("sample_details"),
        shiny::div(class = "inspector-button-row",
          shiny::actionButton("current_previous", "Previous sample", class = "btn-sm btn-light"),
          shiny::actionButton("current_next", "Next sample", class = "btn-sm btn-light")
        ),
        shiny::uiOutput("map_selection_note")
      ),
      shiny::div(
        class = "inspector-card",
        shiny::h4("Inclusive range"),
        shiny::div(class = "inspector-button-row",
          shiny::actionButton("set_start", "Use current as start", class = "btn-sm btn-outline-success"),
          shiny::actionButton("set_end", "Use current as end", class = "btn-sm btn-outline-danger")
        ),
        shiny::numericInput("start_index", "Start sample index", value = NULL, step = 1),
        shiny::div(class = "inspector-nudge-row",
          shiny::actionButton("start_previous", "− previous", class = "btn-sm btn-light"),
          shiny::actionButton("start_next", "+ next", class = "btn-sm btn-light")
        ),
        shiny::numericInput("end_index", "End sample index", value = NULL, step = 1),
        shiny::div(class = "inspector-nudge-row",
          shiny::actionButton("end_previous", "− previous", class = "btn-sm btn-light"),
          shiny::actionButton("end_next", "+ next", class = "btn-sm btn-light")
        ),
        shiny::uiOutput("range_status"),
        shiny::div(class = "inspector-button-row",
          shiny::actionButton("copy_range", "Copy boundaries", class = "btn-sm btn-primary"),
          shiny::actionButton("clear_range", "Clear", class = "btn-sm btn-light")
        )
      )
    )
  ),
  shiny::div(
    class = "inspector-card inspector-timeline-card",
    shiny::div(
      class = "inspector-card-heading",
      shiny::span("Sample timeline"),
      shiny::selectInput("timeline_metric", NULL, choices = character(), width = "250px")
    ),
    plotly::plotlyOutput("sample_timeline", height = "330px")
  )
)

activity_inspector_server <- function(
  input,
  output,
  session,
  loader = load_inspector_activity
) {
  state <- shiny::reactiveValues(
    model = NULL,
    current_index = NULL,
    start_index = NULL,
    end_index = NULL,
    status = "Enter an activity ID to begin.",
    status_type = "info",
    map_note = NULL,
    range_error = NULL
  )

  set_status <- function(message, type = "info") {
    state$status <- message
    state$status_type <- type
  }

  clear_boundary_inputs <- function() {
    session$sendCustomMessage("clear-inspector-number", list(id = "start_index"))
    session$sendCustomMessage("clear-inspector-number", list(id = "end_index"))
  }

  output$load_status <- shiny::renderUI({
    shiny::div(class = paste("inspector-notice", paste0("notice-", state$status_type)), state$status)
  })

  output$activity_metadata <- shiny::renderUI({
    model <- state$model
    if (is.null(model) || nrow(model$activity) == 0L) return(NULL)
    activity <- model$activity[1, , drop = FALSE]
    distance_miles <- activity$distance_metres[[1]] * 0.000621371
    shiny::div(
      class = "inspector-metadata",
      shiny::div(shiny::strong(activity$activity_name[[1]] %||% "Unnamed activity"), shiny::span(as.character(activity$activity_id[[1]]))),
      shiny::div(shiny::span("Date"), shiny::strong(format(as.Date(activity$start_date_local[[1]]), "%d %B %Y"))),
      shiny::div(shiny::span("Type"), shiny::strong(activity$sport_type[[1]] %||% "Missing")),
      shiny::div(shiny::span("Distance"), shiny::strong(format_inspector_value(distance_miles, 1, " mi"))),
      shiny::div(shiny::span("Moving"), shiny::strong(format_inspector_duration(activity$moving_time_seconds[[1]]))),
      shiny::div(shiny::span("Elapsed"), shiny::strong(format_inspector_duration(activity$elapsed_time_seconds[[1]])))
    )
  })

  shiny::observeEvent(input$load_activity, {
    state$map_note <- NULL
    state$range_error <- NULL
    set_status("Loading activity…", "info")
    result <- tryCatch(
      shiny::withProgress(message = "Loading canonical Silver data", value = 0.3, {
        loader(input$activity_id)
      }),
      error = identity
    )
    if (inherits(result, "error")) {
      state$model <- NULL
      set_status(conditionMessage(result), "error")
      return()
    }
    if (nrow(result$activity) == 0L) {
      state$model <- NULL
      set_status("No Silver activity was found for that activity ID.", "warning")
      return()
    }

    model <- tryCatch(
      prepare_inspection_model(result$activity, result$streams),
      error = identity
    )
    if (inherits(model, "error")) {
      state$model <- NULL
      set_status(conditionMessage(model), "error")
      return()
    }
    state$model <- model
    state$current_index <- if (nrow(model$streams)) model$streams$sample_index[[1]] else NULL
    state$start_index <- NULL
    state$end_index <- NULL
    clear_boundary_inputs()
    metric_choices <- stats::setNames(model$metrics$column, model$metrics$label)
    shiny::updateSelectInput(
      session,
      "timeline_metric",
      choices = metric_choices,
      selected = if (length(metric_choices)) unname(metric_choices[[1]]) else character()
    )
    if (nrow(model$streams) == 0L) {
      set_status("Activity loaded, but it has no canonical Silver stream rows.", "warning")
    } else if (nrow(model$route$points) == 0L) {
      set_status(
        paste0("Loaded ", format(nrow(model$streams), big.mark = ","), " samples. No usable GPS coordinates are available."),
        "warning"
      )
    } else {
      set_status(
        paste0("Loaded ", format(nrow(model$streams), big.mark = ","), " canonical samples. Click the route or timeline to inspect one."),
        "success"
      )
    }
  })

  output$activity_map <- leaflet::renderLeaflet({
    model <- state$model
    if (is.null(model)) return(leaflet::leaflet())
    build_inspector_map(model)
  })

  select_from_map <- function(click) {
    if (is.null(state$model) || is.null(click$lat) || is.null(click$lng)) return()
    nearest <- nearest_inspector_sample(state$model, click$lat, click$lng)
    if (is.null(nearest)) return()
    state$current_index <- nearest$sample_index
    state$map_note <- if (nearest$ambiguous) {
      paste0(
        "Several samples are spatially plausible here. Sample ",
        nearest$sample_index,
        " was selected; use the timeline or sample controls to refine it."
      )
    } else {
      paste0("Nearest mapped observation: sample ", nearest$sample_index, ".")
    }
  }
  shiny::observeEvent(input$activity_map_shape_click, {
    select_from_map(input$activity_map_shape_click)
  })

  shiny::observeEvent(plotly::event_data("plotly_click", source = "inspector_timeline"), {
    event <- plotly::event_data("plotly_click", source = "inspector_timeline")
    if (is.null(event$customdata) || is.null(state$model)) return()
    state$current_index <- resolve_inspector_sample_index(state$model, event$customdata[[1]])
    state$map_note <- paste0("Timeline selected canonical sample ", state$current_index, ".")
  })

  output$sample_timeline <- plotly::renderPlotly({
    model <- state$model
    shiny::req(!is.null(model))
    metric <- input$timeline_metric
    if (is.null(metric) || !nzchar(metric)) metric <- if (nrow(model$metrics)) model$metrics$column[[1]] else ""
    build_inspector_timeline(
      model,
      metric,
      state$current_index,
      state$start_index,
      state$end_index
    )
  })

  output$sample_details <- shiny::renderTable({
    shiny::req(!is.null(state$model))
    sample <- inspector_sample(state$model, state$current_index)
    if (nrow(sample) == 0L) return(data.frame(Field = "Sample", Value = "None selected"))
    values <- c(
      "Canonical sample index" = as.character(sample$sample_index[[1]]),
      "Elapsed time" = if (is.na(sample$time_seconds[[1]])) "Missing" else paste0(sample$time_seconds[[1]], " s"),
      "Latitude" = format_inspector_value(sample$latitude[[1]], 6),
      "Longitude" = format_inspector_value(sample$longitude[[1]], 6),
      "Device distance" = format_inspector_value(sample$distance_metres[[1]], 1, " m"),
      "Elevation" = format_inspector_value(sample$altitude_metres[[1]], 1, " m"),
      "Speed" = format_inspector_value(sample$velocity_smooth_metres_per_second[[1]], 2, " m/s"),
      "Heart rate" = format_inspector_value(sample$heartrate_bpm[[1]], 0, " bpm"),
      "Power" = format_inspector_value(sample$watts[[1]], 0, " W"),
      "Cadence" = format_inspector_value(sample$cadence_rpm[[1]], 0, " rpm"),
      "Temperature" = format_inspector_value(sample$temperature_celsius[[1]], 0, " °C"),
      "Moving" = if (is.na(sample$is_moving[[1]])) "Missing" else as.character(sample$is_moving[[1]])
    )
    data.frame(Field = names(values), Value = unname(values), check.names = FALSE)
  }, striped = TRUE, bordered = FALSE, spacing = "xs")

  output$map_selection_note <- shiny::renderUI({
    if (is.null(state$map_note)) return(NULL)
    shiny::div(class = "inspector-note", state$map_note)
  })

  set_boundary <- function(which, value, update_input = TRUE) {
    if (is.null(state$model)) return(FALSE)
    old_value <- state[[paste0(which, "_index")]]
    resolved <- tryCatch(resolve_inspector_sample_index(state$model, value), error = identity)
    if (inherits(resolved, "error")) {
      state$range_error <- conditionMessage(resolved)
      if (update_input && is.null(old_value)) {
        session$sendCustomMessage("clear-inspector-number", list(id = paste0(which, "_index")))
      } else if (update_input) {
        shiny::updateNumericInput(session, paste0(which, "_index"), value = old_value)
      }
      return(FALSE)
    }
    candidate_start <- if (which == "start") resolved else state$start_index
    candidate_end <- if (which == "end") resolved else state$end_index
    if (!is.null(candidate_start) && !is.null(candidate_end) && candidate_start > candidate_end) {
      state$range_error <- "Start sample index must not exceed end sample index."
      if (update_input && is.null(old_value)) {
        session$sendCustomMessage("clear-inspector-number", list(id = paste0(which, "_index")))
      } else if (update_input) {
        shiny::updateNumericInput(session, paste0(which, "_index"), value = old_value)
      }
      return(FALSE)
    }
    state[[paste0(which, "_index")]] <- resolved
    state$range_error <- NULL
    if (update_input) shiny::updateNumericInput(session, paste0(which, "_index"), value = resolved)
    TRUE
  }

  shiny::observeEvent(input$set_start, set_boundary("start", state$current_index))
  shiny::observeEvent(input$set_end, set_boundary("end", state$current_index))
  shiny::observeEvent(input$start_index, {
    if (!is.null(state$model) && !is.null(input$start_index) && !is.na(input$start_index)) {
      set_boundary("start", input$start_index, FALSE)
    }
  }, ignoreInit = TRUE)
  shiny::observeEvent(input$end_index, {
    if (!is.null(state$model) && !is.null(input$end_index) && !is.na(input$end_index)) {
      set_boundary("end", input$end_index, FALSE)
    }
  }, ignoreInit = TRUE)

  move_current <- function(direction) {
    if (is.null(state$model) || is.null(state$current_index)) return()
    state$current_index <- inspector_neighbour_index(state$model, state$current_index, direction)
  }
  shiny::observeEvent(input$current_previous, move_current("previous"))
  shiny::observeEvent(input$current_next, move_current("next"))

  move_boundary <- function(which, direction) {
    value <- state[[paste0(which, "_index")]]
    if (is.null(state$model) || is.null(value)) return()
    set_boundary(which, inspector_neighbour_index(state$model, value, direction))
  }
  shiny::observeEvent(input$start_previous, move_boundary("start", "previous"))
  shiny::observeEvent(input$start_next, move_boundary("start", "next"))
  shiny::observeEvent(input$end_previous, move_boundary("end", "previous"))
  shiny::observeEvent(input$end_next, move_boundary("end", "next"))

  shiny::observeEvent(input$clear_range, {
    state$start_index <- NULL
    state$end_index <- NULL
    state$range_error <- NULL
    clear_boundary_inputs()
  })

  output$range_status <- shiny::renderUI({
    if (!is.null(state$range_error)) {
      return(shiny::div(class = "inspector-range-error", state$range_error))
    }
    if (is.null(state$start_index) || is.null(state$end_index)) {
      return(shiny::div(class = "inspector-range-help", "Set both boundaries to highlight and copy a range."))
    }
    rows <- nrow(inspector_range_streams(state$model, state$start_index, state$end_index))
    shiny::div(
      class = "inspector-range-ok",
      paste0("Samples ", state$start_index, "–", state$end_index, " (", format(rows, big.mark = ","), " stored rows)")
    )
  })

  shiny::observeEvent(input$copy_range, {
    if (is.null(state$model) || is.null(state$start_index) || is.null(state$end_index)) {
      state$range_error <- "Set both valid boundaries before copying."
      return()
    }
    text <- inspector_clipboard_text(state$model, state$start_index, state$end_index)
    session$sendCustomMessage("copy-inspector-boundaries", list(text = text))
    state$range_error <- NULL
  })

  shiny::observe({
    shiny::req(!is.null(state$model))
    update_inspector_map(
      leaflet::leafletProxy("activity_map", session),
      state$model,
      state$current_index,
      state$start_index,
      state$end_index
    )
  })

  shiny::observeEvent(input$fit_full, {
    if (is.null(state$model)) return()
    fit_inspector_points(
      leaflet::leafletProxy("activity_map", session),
      inspector_valid_points(state$model)
    )
  })
  shiny::observeEvent(input$fit_selection, {
    if (is.null(state$model) || is.null(state$start_index) || is.null(state$end_index)) {
      state$range_error <- "Set both valid boundaries before fitting the selected range."
      return()
    }
    points <- inspector_valid_points(state$model, state$start_index, state$end_index)
    if (nrow(points) == 0L) {
      state$range_error <- "The selected range has no usable GPS coordinates to fit."
      return()
    }
    fit_inspector_points(leaflet::leafletProxy("activity_map", session), points)
  })

  invisible(state)
}

`%||%` <- function(value, fallback) {
  if (is.null(value) || length(value) == 0L || all(is.na(value))) fallback else value
}

shiny::shinyApp(activity_inspector_ui, activity_inspector_server)
