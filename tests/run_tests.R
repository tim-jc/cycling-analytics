#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(tidyverse)
  library(lubridate)
  library(plotly)
  library(flexdashboard)
})

Sys.setenv(TZ = "Europe/London")

source("db/db.R")
source("dashboard_identity.R")
source("dashboard_functions.R")
source("latest_ride_functions.R")
source("tbr_functions.R")
source("apps/activity-inspector/R/data_access.R")
source("apps/activity-inspector/R/inspection_model.R")
source("apps/activity-inspector/R/map.R")
source("apps/activity-inspector/R/timeline.R")
source("runtime_helpers.R")
source("reports/ride-summary/R/ride_report_model.R")
source("reports/ride-summary/R/ride_report_components.R")
source("render_dashboard.R")

tests_run <- 0L

run_test <- function(name, code) {
  force(code)
  tests_run <<- tests_run + 1L
  cat(sprintf("PASS: %s\n", name))
}

expect_true <- function(value, message = "Expected TRUE") {
  if (!isTRUE(value)) {
    stop(message, call. = FALSE)
  }
}

expect_equal <- function(actual, expected, tolerance = 1e-8) {
  if (!isTRUE(all.equal(actual, expected, tolerance = tolerance))) {
    stop(
      "Expected ",
      paste(expected, collapse = ", "),
      "; got ",
      paste(actual, collapse = ", "),
      call. = FALSE
    )
  }
}

expect_error <- function(code, pattern) {
  error_message <- tryCatch(
    {
      force(code)
      NA_character_
    },
    error = conditionMessage
  )

  if (is.na(error_message) || !grepl(pattern, error_message, fixed = TRUE)) {
    stop(
      "Expected error containing '",
      pattern,
      "'; got ",
      ifelse(is.na(error_message), "no error", error_message),
      call. = FALSE
    )
  }
}

write_static_site_fixture <- function(path, label = "fixture") {
  dependency_dir <- file.path(path, "index_files", "fixture")
  dir.create(dependency_dir, recursive = TRUE)
  writeLines(
    paste0("console.log('", label, "');"),
    file.path(dependency_dir, "app.js")
  )
  writeLines(
    c(
      "<!doctype html>",
      paste0("<html><body>", label),
      '<script src="index_files/fixture/app.js"></script>',
      "</body></html>"
    ),
    file.path(path, "index.html")
  )
}

run_test("dashboard output defaults to the ignored output directory", {
  project_root <- withr::local_tempdir()
  output_dir <- withr::with_envvar(
    c(CYCLING_ANALYTICS_OUTPUT_DIR = NA),
    get_dashboard_output_dir(project_root)
  )

  expect_equal(output_dir, normalizePath(file.path(project_root, "output")))
})

run_test("dashboard output directory override is preserved", {
  project_root <- withr::local_tempdir()
  configured_output <- file.path(project_root, "custom-site")
  output_dir <- withr::with_envvar(
    c(CYCLING_ANALYTICS_OUTPUT_DIR = configured_output),
    get_dashboard_output_dir(project_root)
  )

  expect_equal(
    output_dir,
    normalizePath(configured_output)
  )
})

run_test("non-self-contained render preserves its dependency tree", {
  fixture_root <- withr::local_tempdir()
  input_file <- file.path(fixture_root, "fixture.Rmd")
  staging_dir <- file.path(fixture_root, "staging")
  render_dir <- file.path(fixture_root, "render")
  dir.create(staging_dir)
  dir.create(render_dir)
  writeLines(
    c(
      "---",
      'title: "Static site fixture"',
      "output:",
      "  html_document:",
      "    self_contained: false",
      "---",
      "",
      "```{r, echo=FALSE}",
      "plotly::plot_ly(x = 1:2, y = 1:2)",
      "```"
    ),
    input_file
  )

  render_dashboard_site(
    input_file,
    staging_dir,
    render_dir,
    new.env(parent = globalenv()),
    quiet = TRUE
  )
  validation <- validate_static_site(staging_dir)

  expect_true(file.exists(file.path(staging_dir, "index.html")))
  expect_true(dir.exists(file.path(staging_dir, "index_files")))
  expect_true(length(validation$dependency_references) > 0L)
})

run_test("incomplete static-site dependencies are rejected", {
  site_dir <- withr::local_tempdir()
  writeLines(
    '<script src="index_files/missing/app.js"></script>',
    file.path(site_dir, "index.html")
  )

  expect_error(
    validate_static_site(site_dir),
    "index_files/ is absent"
  )
})

run_test("failed site promotion restores the complete previous site", {
  output_dir <- withr::local_tempdir()
  staging_dir <- create_static_site_staging_dir(output_dir)
  write_static_site_fixture(output_dir, "old-site")
  write_static_site_fixture(staging_dir, "new-site")

  expect_error(
    promote_static_site(
      staging_dir,
      output_dir,
      step_hook = function(step) {
        if (identical(step, "promoted:index_files")) {
          stop("injected finalisation failure")
        }
      }
    ),
    "injected finalisation failure"
  )

  validate_static_site(output_dir)
  expect_true(grepl(
    "old-site",
    paste(readLines(file.path(output_dir, "index.html")), collapse = ""),
    fixed = TRUE
  ))
  expect_true(!dir.exists(staging_dir))
})

run_test("generated dashboard site is ignored by Git", {
  status <- suppressWarnings(system2(
    "git",
    c("check-ignore", "--quiet", "output/index.html")
  ))

  expect_equal(status, 0L)
})

run_test("dashboard identity dependency packages every local asset", {
  dependency <- dashboard_identity_dependency(normalizePath("."))
  dependency_root <- withr::local_tempdir()
  copied <- htmltools::copyDependencyToDir(dependency, dependency_root)
  copied_root <- unname(copied$src[["file"]])

  expected_files <- c(
    "identity/tokens.css",
    "identity/symbol-dark.svg",
    "identity/favicon.svg",
    "identity/favicon.png",
    "identity/PROVENANCE.md",
    "dashboard.css",
    "dashboard-shell.js"
  )

  expect_true(all(file.exists(file.path(copied_root, expected_files))))
  expect_equal(copied$name, DASHBOARD_IDENTITY_NAME)
  expect_equal(copied$version, DASHBOARD_IDENTITY_VERSION)
})

run_test("dashboard identity dependency uses local favicon and brand paths", {
  dependency <- dashboard_identity_dependency(normalizePath("."))
  dependency_html <- as.character(htmltools::renderDependencies(
    list(dependency),
    srcType = "file"
  ))
  shell_source <- paste(
    readLines("assets/dashboard-shell.js", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl("identity/favicon.png", dependency_html, fixed = TRUE))
  expect_true(grepl("identity/favicon.svg", dependency_html, fixed = TRUE))
  expect_true(grepl("https://pastthegrid.uk/", shell_source, fixed = TRUE))
  expect_true(grepl("Past the Grid", shell_source, fixed = TRUE))
  expect_true(grepl("Cycling Analytics", shell_source, fixed = TRUE))
  expect_true(
    !grepl("https://pastthegrid.uk/assets/", shell_source, fixed = TRUE)
  )
})

run_test("dashboard navbar owns the Coastal reference geometry", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  shell_source <- paste(
    readLines("assets/dashboard-shell.js", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl("--cycling-navbar-height: 60px", css_source, fixed = TRUE))
  expect_true(grepl(".navbar .navbar-logo", css_source, fixed = TRUE))
  expect_true(grepl("display: block", css_source, fixed = TRUE))
  expect_true(grepl("float: left", css_source, fixed = TRUE))
  expect_true(grepl("float: right", css_source, fixed = TRUE))
  expect_true(grepl("height: 30px", css_source, fixed = TRUE))
  expect_true(grepl("width: 30px", css_source, fixed = TRUE))
  expect_true(!grepl("padding-top: 18px", css_source, fixed = TRUE))
  expect_true(!grepl("padding-bottom: 18px", css_source, fixed = TRUE))
  expect_true(grepl("logo.replaceChildren(brand)", shell_source, fixed = TRUE))
  expect_true(grepl('aria-current=\\"page\\"', shell_source))
})

run_test("mobile navigation draws a compact framework-independent hamburger", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl(
    ".navbar-inverse .navbar-toggle > .icon-bar:last-child",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "background-image: none !important",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl("box-shadow:", css_source, fixed = TRUE))
  expect_true(grepl("height: 44px", css_source, fixed = TRUE))
  expect_true(grepl("width: 44px", css_source, fixed = TRUE))
  expect_true(grepl("-webkit-appearance: none", css_source, fixed = TRUE))
  expect_true(
    !grepl(
      ".navbar-toggle .icon-bar {\n  background-color: var(--ptg-paper)",
      css_source,
      fixed = TRUE
    )
  )
})

run_test("dashboard shell constrains mobile flex content and wrapping", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl(
    ".dashboard-column-orientation > .dashboard-column",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl("min-width: 0", css_source, fixed = TRUE))
  expect_true(grepl(
    "#latest-ride #ride-overview .value",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl("overflow-wrap: anywhere", css_source, fixed = TRUE))
  expect_true(grepl("white-space: normal", css_source, fixed = TRUE))
  expect_true(grepl("#map .dashboard-row", css_source, fixed = TRUE))
  expect_true(grepl("overflow-x: clip", css_source, fixed = TRUE))
  expect_true(!grepl("body {\n  overflow-x: hidden", css_source, fixed = TRUE))
})

run_test("dashboard provides page-specific intermediate-width layouts", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  dashboard_source <- paste(
    readLines("dashboards/index.Rmd", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl(
    "@media (min-width: 768px) and (max-width: 1199px)",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(".tablet-summary-metrics", css_source, fixed = TRUE))
  expect_true(grepl(".tablet-trends-metrics", css_source, fixed = TRUE))
  expect_true(grepl(".tablet-best-efforts-detail", css_source, fixed = TRUE))
  expect_true(grepl("flex-wrap: wrap", css_source, fixed = TRUE))
  expect_true(grepl("min-width: 0", css_source, fixed = TRUE))
  expect_true(grepl("tablet-latest-overview", dashboard_source, fixed = TRUE))
  expect_true(grepl("tablet-summary-metrics", dashboard_source, fixed = TRUE))
  expect_true(grepl("tablet-trends-metrics", dashboard_source, fixed = TRUE))
  expect_true(!grepl("body {\n  overflow-x: hidden", css_source, fixed = TRUE))
})

run_test("mobile page navigation closes the existing collapse", {
  shell_source <- paste(
    readLines("assets/dashboard-shell.js", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl("installMobileNavigationClose", shell_source, fixed = TRUE))
  expect_true(grepl("(max-width: 767px)", shell_source, fixed = TRUE))
  expect_true(grepl(
    'collapse.addEventListener("click"',
    shell_source,
    fixed = TRUE
  ))
  expect_true(grepl('event.target.closest', shell_source, fixed = TRUE))
  expect_true(grepl('.navbar-nav a[href^="#"]', shell_source, fixed = TRUE))
  expect_true(grepl('.collapse("hide")', shell_source, fixed = TRUE))
  expect_true(grepl('hidden.bs.collapse', shell_source, fixed = TRUE))
  expect_true(grepl('toggle.focus()', shell_source, fixed = TRUE))
  expect_true(grepl(
    'toggle.setAttribute("aria-expanded", "false")',
    shell_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    'collapse.classList.remove("in", "show")',
    shell_source,
    fixed = TRUE
  ))
})

run_test("dashboard component surfaces use Navigation Instrument tokens", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  dashboard_source <- paste(
    readLines("dashboards/index.Rmd", warn = FALSE),
    collapse = "\n"
  )

  selectors <- c(
    ".latest-ride-notice--unavailable",
    ".latest-ride-highlight",
    ".best-effort-placeholder",
    ".tbr-milestone",
    ".tbr-map-status",
    ".leaflet-control.tbr-focus-control",
    ".tbr-focus-control .tbr-focus-button.is-active"
  )
  expect_true(all(vapply(
    selectors,
    function(selector) grepl(selector, css_source, fixed = TRUE),
    logical(1)
  )))
  expect_true(grepl("var(--ptg-surface)", css_source, fixed = TRUE))
  expect_true(grepl("var(--ptg-muted)", css_source, fixed = TRUE))
  expect_true(grepl("var(--ptg-copper)", css_source, fixed = TRUE))
  expect_true(grepl("var(--ptg-focus)", css_source, fixed = TRUE))
  expect_true(!grepl(".latest-ride-notice {", dashboard_source, fixed = TRUE))
  expect_true(!grepl(".tbr-focus-control {", dashboard_source, fixed = TRUE))
})

run_test("TBR focus buttons reset native and framework presentation", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  identity_environment <- new.env(parent = globalenv())
  sys.source("dashboard_identity.R", envir = identity_environment)

  expect_equal(identity_environment$DASHBOARD_IDENTITY_VERSION, "1.0.6")
  expect_true(grepl("-webkit-appearance: none", css_source, fixed = TRUE))
  expect_true(grepl("appearance: none", css_source, fixed = TRUE))
  expect_true(grepl("border-radius: 0", css_source, fixed = TRUE))
  expect_true(grepl("box-shadow: none", css_source, fixed = TRUE))
  expect_true(grepl(
    "font-family: var(--ptg-font-sans)",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl("text-shadow: none", css_source, fixed = TRUE))
  expect_true(grepl(
    '.tbr-focus-control .tbr-focus-button[aria-pressed="true"]',
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    ".tbr-focus-control .tbr-focus-button:disabled",
    css_source,
    fixed = TRUE
  ))
})

run_test("dashboard Leaflet chrome uses scoped Navigation Instrument styling", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  required_selectors <- c(
    ".dashboard-page .leaflet-bar:not(.tbr-focus-control)",
    ".dashboard-page .leaflet-control-layers",
    ".dashboard-page .leaflet-control.info.legend",
    ".dashboard-page .leaflet-popup-content-wrapper",
    ".dashboard-page .leaflet-popup-tip",
    ".dashboard-page .leaflet-popup-content",
    ".dashboard-page .leaflet-container a.leaflet-popup-close-button",
    ".dashboard-page .leaflet-container .leaflet-control-attribution",
    ".dashboard-page .leaflet-control-attribution a",
    ".latest-ride-virtual-route-label"
  )
  expect_true(all(vapply(
    required_selectors,
    function(selector) grepl(selector, css_source, fixed = TRUE),
    logical(1)
  )))
  expect_true(grepl(
    "background: var(--ptg-midnight)",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "border: 1px solid var(--ptg-line)",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "outline: 3px solid var(--ptg-focus) !important",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "background: rgba(23, 38, 48, .88)",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "max-width: calc(100% - 8px)",
    css_source,
    fixed = TRUE
  ))
  expect_true(!grepl("filter: invert", css_source, fixed = TRUE))
  expect_true(!grepl(".leaflet-tile", css_source, fixed = TRUE))
})

run_test("value boxes use Navigation Instrument hierarchy and resilient text", {
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )
  value_box_sources <- paste(
    unlist(lapply(
      c(
        "dashboard_functions.R",
        "latest_ride_functions.R",
        "dashboards/index.Rmd"
      ),
      readLines,
      warn = FALSE
    )),
    collapse = "\n"
  )

  expect_true(grepl(".value-box .value", css_source, fixed = TRUE))
  expect_true(grepl(".value-box .caption", css_source, fixed = TRUE))
  expect_true(grepl(".value-box .icon i", css_source, fixed = TRUE))
  expect_true(grepl(
    "color: var(--ptg-survey-blue) !important",
    css_source,
    fixed = TRUE
  ))
  expect_true(grepl("font-size: 32px !important", css_source, fixed = TRUE))
  expect_true(grepl("max-width: calc(100% - 44px)", css_source, fixed = TRUE))
  expect_true(grepl("overflow-wrap: anywhere", css_source, fixed = TRUE))
  expect_true(grepl("white-space: normal", css_source, fixed = TRUE))
  expect_true(!grepl("#EDF0F1", value_box_sources, fixed = TRUE))
})

run_test("linked value boxes become native accessible anchors", {
  shell_source <- paste(
    readLines("assets/dashboard-shell.js", warn = FALSE),
    collapse = "\n"
  )
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )

  expect_true(grepl("annotateLinkedValueBoxes", shell_source, fixed = TRUE))
  expect_true(grepl("promoteLinkedValueBoxes", shell_source, fixed = TRUE))
  expect_true(grepl(".value-output[data-href]", shell_source, fixed = TRUE))
  expect_true(grepl("document.createElement('a')", shell_source, fixed = TRUE))
  expect_true(grepl("flexdashboard:layoutcomplete", shell_source, fixed = TRUE))
  expect_true(grepl("link.href = href", shell_source, fixed = TRUE))
  expect_true(grepl("link.target = '_blank'", shell_source, fixed = TRUE))
  expect_true(grepl("noopener noreferrer", shell_source, fixed = TRUE))
  expect_true(!grepl("role = 'button'", shell_source, fixed = TRUE))
  expect_true(!grepl("tabindex", shell_source, fixed = TRUE))
  expect_true(grepl("a.value-box-link:hover", css_source, fixed = TRUE))
  expect_true(grepl("a.value-box-link:focus-visible", css_source, fixed = TRUE))
})

run_test("Navigation Instrument Plotly defaults preserve analytical semantics", {
  original <- plotly::plot_ly(
    x = c(1, 10, 100),
    y = c(100, 200, 300),
    type = "scatter",
    mode = "lines+markers",
    line = list(color = "#123456", width = 3),
    marker = list(color = "#ABCDEF", size = 7),
    hovertemplate = "%{x}: %{y} W<extra></extra>",
    name = "Power"
  ) |>
    plotly::layout(
      hovermode = "closest",
      margin = list(l = 51, r = 17, t = 11, b = 43),
      xaxis = list(
        type = "log",
        range = c(0, 2),
        title = "Duration",
        tickformat = ".1f",
        zeroline = FALSE
      ),
      yaxis = list(
        range = c(0, 350),
        title = "Power (W)",
        rangemode = "tozero"
      ),
      annotations = list(list(text = "Threshold", x = 1, y = 200)),
      shapes = list(list(type = "line", x0 = 1, x1 = 100, y0 = 250, y1 = 250)),
      legend = list(x = 0.25, y = 0.9)
    )
  before <- plotly::plotly_build(original)
  after <- plotly::plotly_build(apply_navigation_instrument_plotly(original))

  expect_equal(length(after$x$data), length(before$x$data))
  expect_equal(after$x$data[[1]]$type, before$x$data[[1]]$type)
  expect_equal(after$x$data[[1]]$mode, before$x$data[[1]]$mode)
  expect_equal(after$x$data[[1]]$line, before$x$data[[1]]$line)
  expect_equal(after$x$data[[1]]$marker, before$x$data[[1]]$marker)
  expect_equal(after$x$data[[1]]$hovertemplate, before$x$data[[1]]$hovertemplate)
  expect_equal(after$x$layout$xaxis$type, before$x$layout$xaxis$type)
  expect_equal(after$x$layout$xaxis$range, before$x$layout$xaxis$range)
  expect_equal(after$x$layout$xaxis$title, before$x$layout$xaxis$title)
  expect_equal(after$x$layout$xaxis$tickformat, before$x$layout$xaxis$tickformat)
  expect_equal(after$x$layout$xaxis$zeroline, FALSE)
  expect_equal(after$x$layout$yaxis$range, before$x$layout$yaxis$range)
  expect_equal(after$x$layout$yaxis$title, before$x$layout$yaxis$title)
  expect_equal(after$x$layout$yaxis$rangemode, before$x$layout$yaxis$rangemode)
  expect_equal(after$x$layout$annotations, before$x$layout$annotations)
  expect_equal(after$x$layout$shapes, before$x$layout$shapes)
  expect_equal(after$x$layout$margin, before$x$layout$margin)
  expect_equal(after$x$layout$hovermode, before$x$layout$hovermode)
  expect_equal(after$x$layout$legend$x, before$x$layout$legend$x)
  expect_equal(after$x$layout$legend$y, before$x$layout$legend$y)
  expect_equal(after$x$layout$plot_bgcolor, PLOTLY_CANVAS_DARK)
  expect_equal(after$x$layout$paper_bgcolor, PLOTLY_CANVAS_DARK)
  expect_equal(after$x$layout$font$color, PLOTLY_IVORY_INK)
  expect_equal(after$x$layout$xaxis$gridcolor, PLOTLY_GRID_LINE)
  expect_equal(after$x$layout$hoverlabel$bgcolor, PLOTLY_MIDNIGHT)
  expect_equal(after$x$layout$hoverlabel$font$color, PLOTLY_IVORY_INK)
  expect_true(after$x$layout$plot_bgcolor != "#F1EFE7")
  expect_true(after$x$layout$paper_bgcolor != "#F1EFE7")
})

run_test("dashboard Plotly paths use the shared presentation helper", {
  dashboard_source <- paste(
    readLines("dashboard_functions.R", warn = FALSE),
    collapse = "\n"
  )
  latest_source <- paste(
    readLines("latest_ride_functions.R", warn = FALSE),
    collapse = "\n"
  )
  tbr_source <- paste(
    readLines("tbr_functions.R", warn = FALSE),
    collapse = "\n"
  )
  css_source <- paste(
    readLines("assets/dashboard.css", warn = FALSE),
    collapse = "\n"
  )

  expect_true(length(gregexpr(
    "apply_navigation_instrument_plotly()",
    dashboard_source,
    fixed = TRUE
  )[[1]]) >= 5L)
  expect_true(length(gregexpr(
    "apply_navigation_instrument_plotly()",
    latest_source,
    fixed = TRUE
  )[[1]]) >= 3L)
  expect_true(grepl(
    "apply_navigation_instrument_plotly()",
    tbr_source,
    fixed = TRUE
  ))
  expect_true(grepl(".plotly .modebar-btn path", css_source, fixed = TRUE))
  expect_true(grepl("fill: var(--ptg-copper) !important", css_source, fixed = TRUE))
})

run_test("dark Plotly charts use explicit Navigation Instrument trace hierarchy", {
  dashboard_source <- paste(
    readLines("dashboard_functions.R", warn = FALSE),
    collapse = "\n"
  )
  latest_source <- paste(
    readLines("latest_ride_functions.R", warn = FALSE),
    collapse = "\n"
  )
  tbr_source <- paste(
    readLines("tbr_functions.R", warn = FALSE),
    collapse = "\n"
  )

  expect_equal(PLOTLY_CANVAS_DARK, "#1C303B")
  expect_equal(PLOTLY_COPPER, "#D18B58")
  expect_equal(PLOTLY_SURVEY_BLUE, "#8BA9B7")
  expect_true(grepl(
    'yr_lbl == "ytd"',
    dashboard_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "PLOTLY_SURVEY_BLUE",
    dashboard_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    '"Current year" = PLOTLY_COPPER',
    dashboard_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    '"All time" = PLOTLY_SURVEY_BLUE',
    dashboard_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "line = list(color = PLOTLY_COPPER, width = 3)",
    latest_source,
    fixed = TRUE
  ))
  expect_true(grepl(
    "high = PLOTLY_COPPER",
    tbr_source,
    fixed = TRUE
  ))

  power_curve <- draw_latest_ride_power_curve(tibble::tibble(
    duration_seconds = c(5, 60, 300),
    peak_value = c(900, 420, 310)
  )) |>
    plotly::plotly_build()
  expect_equal(length(power_curve$x$data), 1L)
  expect_equal(power_curve$x$data[[1]]$line$color, PLOTLY_COPPER)
  expect_equal(power_curve$x$data[[1]]$marker$color, PLOTLY_SURVEY_BLUE)
  expect_equal(power_curve$x$layout$plot_bgcolor, PLOTLY_CANVAS_DARK)
})

run_test("year comparisons expose years without changing observed or projected data", {
  current_year <- lubridate::year(Sys.Date())
  previous_year <- current_year - 1L
  fixture <- dplyr::bind_rows(
    tibble::tibble(
      yr_lbl = "pytd",
      yr = previous_year,
      yr_day = c(1, 90, 180),
      metric_value = c(0, 900, 2100)
    ),
    tibble::tibble(
      yr_lbl = "ytd",
      yr = current_year,
      yr_day = c(1, 90, 180),
      metric_value = c(0, 1050, 2450)
    )
  ) |>
    dplyr::mutate(
      activity_id = dplyr::row_number(),
      start_date_local = as.Date(sprintf("%d-01-01", .data$yr)) +
        .data$yr_day - 1,
      ytd_distance_mi = .data$metric_value,
      ytd_elevation_m = .data$metric_value * 10,
      ytd_tons = floor(.data$metric_value / 100),
      ytd_val = TRUE,
      is_ton_day = FALSE
    ) |>
    dplyr::select(-"metric_value")

  built <- draw_ytd_curve("ytd_distance_mi", fixture) |>
    plotly::plotly_build()

  expect_equal(length(built$x$data), 6L)
  expect_equal(
    vapply(built$x$data[1:2], `[[`, character(1), "name"),
    as.character(c(previous_year, current_year))
  )
  expect_equal(
    vapply(built$x$data[3:4], function(trace) trace$line$dash, character(1)),
    c("dash", "dash")
  )
  expect_equal(as.numeric(built$x$data[[1]]$y), c(0, 900, 2100))
  expect_equal(as.numeric(built$x$data[[2]]$y), c(0, 1050, 2450))
  expect_equal(as.numeric(built$x$data[[3]]$x), c(1, 365))
  expect_equal(as.numeric(built$x$data[[4]]$x), c(1, 365))
  expect_equal(
    as.numeric(built$x$data[[3]]$y),
    c(0, (2100 / 180) * 365)
  )
  expect_equal(
    as.numeric(built$x$data[[4]]$y),
    c(0, (2450 / 180) * 365)
  )
  expect_true(isTRUE(built$x$layout$showlegend))
  expect_equal(built$x$layout$annotations[[1]]$text, "Dashed = projected")
})

run_test("weekly volume identifies its unchanged four-week rolling average", {
  fixture <- tibble::tibble(
    start_date_local = seq.Date(Sys.Date() - 84, Sys.Date(), by = "7 days"),
    distance_mi = seq(30, 66, length.out = 13),
    moving_time_hr = distance_mi / 15,
    energy_kilojoules = distance_mi * 25,
    elevation_gain_m = distance_mi * 10
  )
  weekly <- build_weekly_training_volume(fixture)
  expected_average <- vapply(
    seq_len(nrow(weekly)),
    function(index) {
      mean(weekly$distance_mi[seq.int(max(1, index - 3), index)])
    },
    numeric(1)
  )
  built <- draw_weekly_training_volume(fixture, "distance_mi") |>
    plotly::plotly_build()

  expect_equal(length(built$x$data), 2L)
  expect_equal(built$x$data[[2]]$name, "4-week rolling average")
  expect_true(isTRUE(built$x$data[[2]]$showlegend))
  expect_equal(as.numeric(built$x$data[[2]]$y), expected_average)
  expect_true(isTRUE(built$x$layout$showlegend))
})

run_test("Critical Power exposes its existing period labels and values", {
  suppressPackageStartupMessages(library(DBI))
  if (!methods::isClass("TestPeakConnection")) {
    methods::setClass(
      "TestPeakConnection",
      contains = "DBIConnection",
      slots = c(rows = "data.frame")
    )
    methods::setMethod(
      "dbGetQuery",
      signature(conn = "TestPeakConnection", statement = "character"),
      function(conn, statement, ...) conn@rows
    )
  }
  current_year <- lubridate::year(Sys.Date())
  rows <- tidyr::expand_grid(
    activity_id = 1:2,
    duration_seconds = c(5, 60, 300)
  ) |>
    dplyr::mutate(
      start_date_local = as.POSIXct(dplyr::if_else(
        .data$activity_id == 1,
        sprintf("%d-06-01", current_year),
        sprintf("%d-06-01", current_year - 1L)
      ), tz = "UTC"),
      sport_type = "Ride",
      metric_name = "watts",
      peak_value = 1000 / log10(.data$duration_seconds + 10) -
        .data$activity_id * 5,
      peak_period = "All time"
    ) |>
    as.data.frame()
  connection <- methods::new("TestPeakConnection", rows = rows)
  built <- draw_critical_metric_curve("power", connection) |>
    plotly::plotly_build()

  expect_equal(length(built$x$data), 6L)
  expect_equal(
    vapply(built$x$data[1:3], `[[`, character(1), "name"),
    c("All time", "Current year", "Last year")
  )
  expect_true(all(vapply(
    built$x$data[1:3],
    function(trace) isTRUE(trace$showlegend),
    logical(1)
  )))
  expect_true(isTRUE(built$x$layout$showlegend))
  expect_equal(
    sort(as.numeric(built$x$data[[2]]$y)),
    sort(rows$peak_value[rows$activity_id == 1])
  )
})

run_test("presentation components expose semantic surface states", {
  information <- as.character(latest_ride_notice("Information"))
  unavailable <- as.character(latest_ride_notice("Unavailable", "unavailable"))
  placeholder <- as.character(draw_best_effort_placeholder(
    "No effort",
    "No telemetry"
  ))
  focus_javascript <- tbr_focus_control_javascript()

  expect_true(grepl(
    "latest-ride-notice--information",
    information,
    fixed = TRUE
  ))
  expect_true(grepl(
    "latest-ride-notice--unavailable",
    unavailable,
    fixed = TRUE
  ))
  expect_true(grepl(
    "best-effort-placeholder__title",
    placeholder,
    fixed = TRUE
  ))
  expect_true(grepl(
    "best-effort-placeholder__detail",
    placeholder,
    fixed = TRUE
  ))
  expect_true(!grepl("background: #f8fafc", placeholder, fixed = TRUE))
  expect_true(grepl("aria-pressed", focus_javascript, fixed = TRUE))
  expect_true(grepl("is-active", focus_javascript, fixed = TRUE))
})

run_test("container logging defaults to stdout without a log file", {
  withr::local_envvar(c(
    DASHBOARD_LOG = NA,
    RENV_PROJECT = "/opt/cycling-analytics"
  ))

  expect_true(is.na(dashboard_log_path()))
})

run_test("writable runtime directories are accepted and probed cleanly", {
  parent_dir <- withr::local_tempdir()
  runtime_dir <- file.path(parent_dir, "render")

  prepared <- prepare_writable_directory(runtime_dir, "Test runtime")

  expect_equal(prepared, normalizePath(runtime_dir))
  expect_equal(
    list.files(runtime_dir, all.files = TRUE, no.. = TRUE),
    character()
  )
})

run_test("nested dashboard stages restore the outer failure context", {
  old_stage <- getOption("cycling_analytics_stage", NULL)
  on.exit(options(cycling_analytics_stage = old_stage), add = TRUE)
  options(cycling_analytics_stage = "Outer stage")

  run_dashboard_stage("Inner stage", {
    expect_equal(getOption("cycling_analytics_stage"), "Inner stage")
  })

  expect_equal(getOption("cycling_analytics_stage"), "Outer stage")
})

run_test("failed dashboard stage remains available to the final handler", {
  old_failed_stage <- getOption("cycling_analytics_failed_stage", NULL)
  on.exit(
    options(cycling_analytics_failed_stage = old_failed_stage),
    add = TRUE
  )
  options(cycling_analytics_failed_stage = NULL)

  tryCatch(
    run_dashboard_stage("Render dashboard", stop("file connection failed")),
    error = function(e) NULL
  )

  expect_equal(
    getOption("cycling_analytics_failed_stage"),
    "Render dashboard"
  )
})

run_test("missing CARTO key gives an actionable, non-secret error", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = NA)
  error_message <- tryCatch(
    carto_basemap_api_key(),
    error = conditionMessage
  )

  expect_true(grepl("CARTO_BASEMAP_API_KEY", error_message, fixed = TRUE))
  expect_true(!grepl("test-carto-key", error_message, fixed = TRUE))
})

run_test("CARTO tile URL preserves the Voyager basemap and adds the key", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  tile_url <- carto_basemap_tile_url("voyager_labels_under")

  expect_equal(
    tile_url,
    paste0(
      "https://{s}.basemaps.cartocdn.com/",
      "rastertiles/voyager_labels_under/{z}/{x}/{y}.png?key=test-carto-key"
    )
  )
})

run_test("CARTO tile URL preserves the Positron basemap", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")

  expect_true(grepl(
    "/light_all/{z}/{x}/{y}.png?key=test-carto-key",
    carto_basemap_tile_url("positron"),
    fixed = TRUE
  ))
})

run_test("CARTO configuration does not print the configured key", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  output <- capture.output(api_key <- carto_basemap_api_key())

  expect_equal(output, character())
  expect_equal(api_key, "test-carto-key")
})

metres_per_mile <- 1 / 0.000621371
reference_date <- as.Date("2026-07-26")

activities <- tibble(
  activity_id = c(1, 2, 3),
  sport_type = c("Ride", "Ride", "VirtualRide"),
  start_datetime_local = as.POSIXct(c(
    "2026-07-20 08:00:00",
    "2026-07-21 08:00:00",
    "2025-07-20 08:00:00"
  )),
  start_date_local = as.Date(c("2026-07-20", "2026-07-21", "2025-07-20")),
  distance_metres = c(10, 20, 5) * metres_per_mile,
  moving_time_seconds = c(3600, 7200, 1800),
  elevation_gain_metres = c(100, 200, 0),
  energy_kilojoules = c(500, NA, 250)
)

streams <- tibble(
  activity_id = 1,
  sport_type = "Ride",
  start_date_local = as.Date("2026-07-20"),
  latitude = 51.5,
  longitude = -0.1,
  stream_order = 1L
)

run_test("activity without streams remains in the activity summary", {
  summary <- build_activity_summary(activities)

  expect_equal(nrow(summary), 3L)
  expect_true(2 %in% summary$activity_id)
  expect_true(!2 %in% streams$activity_id)
  expect_equal(
    sum(summary$distance_mi[year(summary$start_date_local) == 2026]),
    30
  )
})

notification_render_env <- new.env(parent = emptyenv())
notification_render_env$ytd_stats <- build_ytd_stats(activities, reference_date)
notification_render_env$activities <- activities

notification_next_line <- function(supplied_text) {
  withr::local_envvar(c(
    CYCLING_ANALYTICS_NEXT_REFRESH_TEXT = supplied_text
  ))

  context <- build_notification_context(
    notification_render_env,
    as.POSIXct("2026-07-26 12:00:00", tz = "Europe/London")
  )
  grep("^Next refresh:", strsplit(context, "\n")[[1]], value = TRUE)[[1]]
}

run_test("render notification displays infrastructure 20:30 value", {
  expect_equal(notification_next_line("20:30"), "Next refresh: 20:30")
})

run_test("render notification displays infrastructure 02:30 value", {
  expect_equal(notification_next_line("02:30"), "Next refresh: 02:30")
})

run_test("render notification displays infrastructure unscheduled value", {
  expect_equal(
    notification_next_line("not scheduled"),
    "Next refresh: not scheduled"
  )
})

run_test("render notification does not derive a missing production value", {
  expect_equal(notification_next_line(NA), "Next refresh: not scheduled")
})

run_test("render notification treats an empty production value as unscheduled", {
  expect_equal(notification_next_line(""), "Next refresh: not scheduled")
})

run_test("obsolete local publish mode is rejected before rendering", {
  project_root <- withr::local_tempdir()
  withr::local_envvar(c(CYCLING_ANALYTICS_RUN_MODE = "local_publish"))
  expect_error(
    get_application_config(project_root),
    "must be one of: render"
  )
})

dashboard_refresh_summary <- function(supplied_next_refresh = NA_character_) {
  withr::local_envvar(c(
    CYCLING_ANALYTICS_NEXT_REFRESH_TEXT = supplied_next_refresh
  ))

  as.character(build_dashboard_refresh_summary(
    as.POSIXct("2026-08-31 12:34:00", tz = "Europe/London")
  ))
}

run_test("dashboard summary displays infrastructure 20:30 value", {
  expect_equal(
    dashboard_refresh_summary("20:30"),
    "Last refresh: 12:34<br>Next refresh: 20:30"
  )
})

run_test("dashboard summary displays infrastructure 02:30 value", {
  expect_equal(
    dashboard_refresh_summary("02:30"),
    "Last refresh: 12:34<br>Next refresh: 02:30"
  )
})

run_test("dashboard summary displays infrastructure unscheduled value", {
  expect_equal(
    dashboard_refresh_summary("not scheduled"),
    "Last refresh: 12:34<br>Next refresh: not scheduled"
  )
})

run_test("dashboard summary defaults a missing production value", {
  expect_equal(
    dashboard_refresh_summary(NA_character_),
    "Last refresh: 12:34<br>Next refresh: not scheduled"
  )
})

run_test("dashboard summary defaults an empty production value", {
  expect_equal(
    dashboard_refresh_summary(""),
    "Last refresh: 12:34<br>Next refresh: not scheduled"
  )
})

run_test("render runtime exposes no Git publication operations", {
  expect_true(!exists("publish_to_git", mode = "function"))
  expect_true(!exists("send_ntfy_message", mode = "function"))
})

notification_activity_fixture <- tibble(
  activity_id = c(20010000001, 20025109853, 20030000001),
  sport_type = c("Ride", "VirtualRide", "Run"),
  start_datetime_local = as.POSIXct(c(
    "2026-08-31 08:00:00",
    "2026-09-03 20:16:34",
    "2026-09-04 08:00:00"
  )),
  start_date_local = as.Date(c("2026-08-31", "2026-09-03", "2026-09-04")),
  distance_metres = c(50 * METRES_PER_MILE, 30224.1, 10 * METRES_PER_MILE),
  moving_time_seconds = c(10800, 3641, 3600)
)

run_test("notification selects newest cycling activity without significance filtering", {
  selected <- select_latest_cycling_activity(notification_activity_fixture)
  expect_equal(selected$activity_id, 20025109853)
  expect_true(selected$distance_metres / METRES_PER_MILE < 20)
})

run_test("newer short ride supersedes older significant ride in notification", {
  fixture <- notification_activity_fixture |>
    dplyr::filter(.data$sport_type == "Ride") |>
    dplyr::bind_rows(tibble(
      activity_id = 20020000002,
      sport_type = "Ride",
      start_datetime_local = as.POSIXct("2026-09-02 08:00:00"),
      start_date_local = as.Date("2026-09-02"),
      distance_metres = 3 * METRES_PER_MILE,
      moving_time_seconds = 900
    ))
  expect_equal(select_latest_cycling_activity(fixture)$activity_id, 20020000002)
})

run_test("current 3 September virtual ride supersedes 31 August ride", {
  fixture <- notification_activity_fixture |>
    dplyr::filter(.data$activity_id %in% c(20010000001, 20025109853))
  expect_equal(select_latest_cycling_activity(fixture)$activity_id, 20025109853)
})

run_test("virtual notification includes a concise qualifier", {
  expect_equal(
    as.character(get_latest_ride_summary(notification_activity_fixture)),
    "Latest ride: 18.8 mi (virtual) on 03 Sep"
  )
})

run_test("outdoor notification remains concise", {
  outdoor <- notification_activity_fixture |>
    dplyr::filter(.data$activity_id == 20010000001)
  expect_equal(
    as.character(get_latest_ride_summary(outdoor)),
    "Latest ride: 50.0 mi on 31 Aug"
  )
})

run_test("notification selection is independent of Latest Ride significance", {
  short_virtual <- notification_activity_fixture |>
    dplyr::filter(.data$activity_id == 20025109853) |>
    dplyr::mutate(moving_time_seconds = 10 * 60)
  expect_equal(
    select_latest_cycling_activity(short_virtual)$activity_id,
    20025109853
  )
  expect_equal(nrow(select_latest_significant_activity(short_virtual)), 0L)
})

run_test("latest ride uses start time when rides share a date", {
  same_day <- tibble(
    activity_id = c(19501207283, 19502918454),
    sport_type = c("Ride", "Ride"),
    start_datetime_local = as.POSIXct(c(
      "2026-07-28 05:13:09",
      "2026-07-28 17:18:51"
    )),
    start_date_local = as.Date(c("2026-07-28", "2026-07-28")),
    distance_metres = c(213806, 13047.5)
  )
  latest <- select_latest_ride(same_day)

  expect_equal(latest$activity_id, 19502918454)
})

run_test("activity without streams contributes to YTD totals", {
  ytd <- build_ytd_stats(activities, reference_date = reference_date)
  current <- ytd |>
    filter(yr == 2026, ytd_val)

  expect_equal(current$ytd_distance_mi, 30)
  expect_equal(current$ytd_time_hr, 3)
  expect_equal(current$ytd_elevation_m, 300)
})

run_test("calendar-year boundary keeps current and previous year separate", {
  boundary_activities <- activities |>
    slice(1:2) |>
    mutate(
      start_date_local = as.Date(c("2025-12-31", "2026-01-01")),
      distance_metres = c(10, 20) * metres_per_mile
    )
  ytd <- build_ytd_stats(
    boundary_activities,
    reference_date = as.Date("2026-01-01")
  )

  expect_equal(
    ytd |> filter(yr == 2026, ytd_val) |> pull(ytd_distance_mi),
    20
  )
  expect_equal(
    ytd |>
      filter(yr == 2025) |>
      summarise(value = max(yr_distance_mi)) |>
      pull(value),
    10
  )
})

run_test("empty weekly periods are represented as zero", {
  summary <- build_activity_summary(activities |> slice(1))
  weekly <- build_weekly_training_volume(
    summary,
    completed_weeks = 4,
    reference_date = reference_date
  )

  expect_equal(nrow(weekly), 5L)
  expect_equal(sum(weekly$distance_mi == 0), 4L)
  expect_equal(sum(weekly$is_current_week), 1L)
})

run_test("missing power remains missing in presentation smoothing", {
  best_efforts <- tibble(
    activity_id = 1,
    duration_seconds = 600,
    start_sample_index = 1,
    end_sample_index = 2
  )
  effort_streams <- tibble(
    activity_id = c(1, 1),
    duration_seconds = c(600, 600),
    stream_order = c(1, 2),
    distance_metres = c(0, 100),
    watts = c(NA_real_, NA_real_)
  )
  prepared <- prepare_best_effort_stream(
    effort_streams,
    best_efforts,
    duration_seconds = 600
  )

  expect_true(all(is.na(prepared$power_smooth)))
})

run_test("empty outdoor streams return four placeholder extrema", {
  empty_streams <- tibble(
    sport_type = character(),
    latitude = double(),
    longitude = double()
  )
  extrema <- get_position_extremities(empty_streams)

  expect_equal(extrema$extremity, c("N", "S", "E", "W"))
})

geocode_stream_fixture <- tibble(
  sport_type = "Ride",
  latitude = c(51.0, 52.0, 51.5, 51.6),
  longitude = c(-1.0, -0.5, -2.0, 1.0)
)

mock_geocoding_error <- function(message, class = "curl_error") {
  structure(
    list(message = message, call = NULL),
    class = c(class, "error", "condition")
  )
}

successful_geocoder <- function(positions) {
  positions |>
    mutate(city = paste0("Place ", row_number()))
}

run_test("successful optional geocoding enriches extrema", {
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = successful_geocoder,
    cache = new.env(parent = emptyenv())
  )
  expect_true(all(extrema$geocode_status == "resolved"))
  expect_true(all(grepl("^Place ", extrema$city)))
})

run_test("optional geocoding connection failure preserves coordinates", {
  warnings <- character()
  calls <- 0L
  cache <- new.env(parent = emptyenv())
  failed_geocoder <- function(positions) {
    calls <<- calls + 1L
    stop(mock_geocoding_error("Couldn't connect to server"))
  }
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = failed_geocoder,
    cache = cache,
    warn = function(message, ...) warnings <<- c(warnings, message)
  )
  get_position_extremities(
    geocode_stream_fixture,
    geocoder = failed_geocoder,
    cache = cache,
    warn = function(message, ...) warnings <<- c(warnings, message)
  )
  expect_equal(extrema$latitude, c(51, 52, 51.5, 51.6))
  expect_true(all(extrema$geocode_status == "failed"))
  expect_equal(calls, 1L)
  expect_equal(length(warnings), 1L)
  expect_true(grepl("Coordinates were preserved", warnings[[1]], fixed = TRUE))
})

run_test("optional geocoding timeout degrades gracefully", {
  failed_geocoder <- function(positions) {
    stop(mock_geocoding_error("Timeout was reached after 4001 milliseconds"))
  }
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = failed_geocoder,
    cache = new.env(parent = emptyenv()),
    warn = function(...) invisible(NULL)
  )
  expect_true(all(extrema$geocode_status == "failed"))
})

run_test("cached geographic enrichment is preserved without another request", {
  cache <- new.env(parent = emptyenv())
  keys <- position_geocode_cache_key(
    geocode_stream_fixture$latitude,
    geocode_stream_fixture$longitude
  )
  for (index in seq_along(keys)) {
    cached_value <- stats::setNames(
      as.list(rep(NA_character_, length(POSITION_GEOCODE_FIELDS))),
      POSITION_GEOCODE_FIELDS
    )
    cached_value$city <- paste0("Cached ", index)
    cached_value$geocode_status <- "resolved"
    assign(
      keys[[index]],
      cached_value,
      envir = cache
    )
  }
  calls <- 0L
  should_not_run <- function(positions) {
    calls <<- calls + 1L
    stop("unexpected request")
  }
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = should_not_run,
    cache = cache
  )
  expect_equal(calls, 0L)
  expect_true(all(grepl("^Cached ", extrema$city)))
})

run_test("unresolved locations remain distinct from service failures", {
  unresolved_geocoder <- function(positions) positions
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = unresolved_geocoder,
    cache = new.env(parent = emptyenv())
  )
  expect_true(all(extrema$geocode_status == "unresolved"))
  expect_true(all(is.na(extrema$city)))
  value_box <- get_coord_valuebox("N", extrema)
  expect_true(grepl("Unknown location", as.character(value_box), fixed = TRUE))
})

run_test("optional geocoding does not swallow programming errors", {
  broken_geocoder <- function(positions) stop("unexpected result-shape bug")
  expect_error(
    get_position_extremities(
      geocode_stream_fixture,
      geocoder = broken_geocoder,
      cache = new.env(parent = emptyenv())
    ),
    "unexpected result-shape bug"
  )
})

run_test("geocoding failure does not affect ride selection or metrics", {
  ride_fixture <- tibble(
    activity_id = c(1, 2),
    sport_type = c("Ride", "VirtualRide"),
    start_datetime_local = as.POSIXct(c(
      "2026-10-01 08:00:00",
      "2026-10-02 08:00:00"
    )),
    distance_metres = c(25, 10) * METRES_PER_MILE,
    moving_time_seconds = c(3600, 1800)
  )
  selected_before <- select_latest_significant_activity(ride_fixture)
  distance_before <- sum(ride_fixture$distance_metres)
  failed_geocoder <- function(positions) {
    stop(mock_geocoding_error(
      "Failed to connect to nominatim.openstreetmap.org"
    ))
  }
  extrema <- get_position_extremities(
    geocode_stream_fixture,
    geocoder = failed_geocoder,
    cache = new.env(parent = emptyenv()),
    warn = function(...) invisible(NULL)
  )
  selected_after <- select_latest_significant_activity(ride_fixture)
  expect_equal(selected_after$activity_id, selected_before$activity_id)
  expect_equal(sum(ride_fixture$distance_metres), distance_before)
  expect_true(nrow(extrema) > 0L)
})

latest_ride_fixture <- tibble(
  activity_id = c(1, 2, 3, 4),
  sport_type = c("Ride", "Ride", "VirtualRide", "Run"),
  start_datetime_local = as.POSIXct(c(
    "2026-07-20 08:00:00",
    "2026-07-22 08:00:00",
    "2026-07-23 08:00:00",
    "2026-07-24 08:00:00"
  )),
  distance_metres = c(19.9, 20, 18.8, 50) * METRES_PER_MILE,
  moving_time_seconds = c(3600, 3600, 3641, 3600)
)

run_test("Latest Ride skips a newer activity under 20 miles", {
  fixture <- latest_ride_fixture |>
    dplyr::filter(.data$activity_id %in% c(1, 2))
  selected <- select_latest_significant_activity(fixture)
  expect_equal(selected$activity_id, 2)
})

run_test("Latest Ride includes exactly 20 miles", {
  selected <- select_latest_significant_activity(
    latest_ride_fixture |> dplyr::slice(2)
  )
  expect_equal(selected$activity_id, 2)
})

run_test("Latest Ride chooses the newest qualifying cycling activity", {
  selected <- select_latest_significant_activity(latest_ride_fixture)
  expect_equal(selected$activity_id, 3)
})

run_test("Latest Ride includes substantive virtual sessions below 20 miles", {
  selected <- select_latest_significant_activity(
    latest_ride_fixture |> dplyr::slice(3)
  )
  expect_equal(selected$activity_id, 3)
})

run_test("Latest Ride includes a VirtualRide lasting exactly 20 minutes", {
  virtual <- latest_ride_fixture |>
    dplyr::slice(3) |>
    dplyr::mutate(moving_time_seconds = 20 * 60)
  expect_equal(select_latest_significant_activity(virtual)$activity_id, 3)
})

run_test("Latest Ride excludes aborted indoor sessions", {
  aborted <- latest_ride_fixture |>
    dplyr::slice(3) |>
    dplyr::mutate(moving_time_seconds = 19 * 60)
  expect_equal(nrow(select_latest_significant_activity(aborted)), 0L)
})

run_test("Latest Ride does not qualify a short Ride by duration", {
  long_short_ride <- latest_ride_fixture |>
    dplyr::slice(1) |>
    dplyr::mutate(moving_time_seconds = 20 * 60)
  expect_equal(nrow(select_latest_significant_activity(long_short_ride)), 0L)
})

run_test("activity queries and selectors do not depend on trainer flag", {
  production_functions <- c(
    paste(deparse(body(get_activities)), collapse = "\n"),
    paste(deparse(body(get_tbr_activities)), collapse = "\n"),
    paste(deparse(body(get_tbr_position_streams)), collapse = "\n"),
    paste(deparse(body(get_latest_significant_ride)), collapse = "\n"),
    paste(deparse(body(select_latest_significant_activity)), collapse = "\n"),
    paste(deparse(body(get_latest_ride_summary)), collapse = "\n")
  )
  expect_true(!any(grepl("is_trainer", production_functions, fixed = TRUE)))
})

run_test("Latest Ride excludes non-cycling activities", {
  selected <- select_latest_significant_activity(
    latest_ride_fixture |> dplyr::slice(4)
  )
  expect_equal(nrow(selected), 0L)
})

run_test("Latest Ride has an explicit empty state with the selection rule", {
  selected <- select_latest_significant_activity(
    latest_ride_fixture |> dplyr::slice(1)
  )
  expect_equal(nrow(selected), 0L)
  empty_message <- latest_ride_empty_message()
  expect_true(grepl("at least 20 miles", empty_message, fixed = TRUE))
  expect_true(grepl("at least 20 minutes", empty_message, fixed = TRUE))
})

run_test("missing one Latest Ride stream does not suppress other traces", {
  partial_streams <- tibble(
    altitude_metres = c(100, 105),
    watts = c(NA_real_, NA_real_),
    heartrate_bpm = c(130, 135),
    latitude = c(51.5, 51.6),
    longitude = c(-0.1, -0.2)
  )
  availability <- latest_ride_stream_availability(partial_streams)
  expect_true(availability[["elevation"]])
  expect_true(!availability[["power"]])
  expect_true(availability[["heart_rate"]])
  expect_true(availability[["gps"]])
})

latest_ride_route_fixture <- function(
  latitude = c(51.5, 51.51, 51.52),
  longitude = c(-0.12, -0.11, -0.10),
  sample_index = seq_along(latitude)
) {
  tibble(sample_index, latitude, longitude)
}

leaflet_call_methods <- function(map) {
  vapply(map$x$calls, `[[`, character(1), "method")
}

run_test("valid outdoor Latest Ride route renders with existing presentation", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  map <- draw_latest_ride_map(latest_ride_route_fixture(), "Ride")
  methods <- leaflet_call_methods(map)
  line_options <- map$x$calls[[which(methods == "addPolylines")]]$args[[4]]

  expect_true(inherits(map, "leaflet"))
  expect_equal(methods, c("addTiles", "addPolylines"))
  expect_true(grepl("light_all", map$x$calls[[1]]$args[[1]], fixed = TRUE))
  expect_equal(line_options$color, "#17324D")
  expect_equal(line_options$weight, 2)
  expect_equal(line_options$opacity, 0.9)
  expect_equal(map$x$limits$lat, c(51.5, 51.52))
  expect_equal(map$x$limits$lng, c(-0.12, -0.10))
})

run_test("valid VirtualRide route renders and is labelled virtual", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  map <- draw_latest_ride_map(latest_ride_route_fixture(), "VirtualRide")
  methods <- leaflet_call_methods(map)
  control <- map$x$calls[[which(methods == "addControl")]]

  expect_true(inherits(map, "leaflet"))
  expect_true("addPolylines" %in% methods)
  expect_equal(control$args[[1]], "Virtual route")
  expect_equal(
    control$args[[4]],
    "latest-ride-virtual-route-label"
  )
})

run_test("VirtualRide without positions shows a route notice", {
  result <- draw_latest_ride_map(
    latest_ride_route_fixture(NA_real_, NA_real_),
    "VirtualRide"
  )
  expect_true(inherits(result, "shiny.tag"))
  expect_true(grepl(
    "A usable route is unavailable for this ride.",
    as.character(result),
    fixed = TRUE
  ))
})

run_test("latitude and longitude on different rows do not form a route", {
  prepared <- prepare_latest_ride_route(latest_ride_route_fixture(
    latitude = c(51.5, NA_real_),
    longitude = c(NA_real_, -0.1)
  ))
  expect_true(!prepared$eligible)
  expect_equal(nrow(prepared$points), 0L)
})

run_test("non-finite Latest Ride coordinates are excluded", {
  prepared <- prepare_latest_ride_route(latest_ride_route_fixture(
    latitude = c(51.5, Inf, 51.6),
    longitude = c(-0.2, -0.15, -0.1)
  ))
  expect_true(prepared$eligible)
  expect_equal(prepared$points$sample_index, c(1L, 3L))
})

run_test("out-of-range Latest Ride coordinates are excluded", {
  prepared <- prepare_latest_ride_route(latest_ride_route_fixture(
    latitude = c(51.5, 91, 51.6, -91),
    longitude = c(-0.2, -0.15, -0.1, 181)
  ))
  expect_true(prepared$eligible)
  expect_equal(prepared$points$sample_index, c(1L, 3L))
})

run_test("a single valid Latest Ride coordinate does not qualify", {
  prepared <- prepare_latest_ride_route(latest_ride_route_fixture(
    latitude = 51.5,
    longitude = -0.1
  ))
  expect_true(!prepared$eligible)
})

run_test("repeated identical Latest Ride coordinates do not qualify", {
  prepared <- prepare_latest_ride_route(latest_ride_route_fixture(
    latitude = rep(51.5, 3),
    longitude = rep(-0.1, 3)
  ))
  expect_true(!prepared$eligible)
})

run_test("invalid Latest Ride samples split rather than bridge route lines", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  streams <- latest_ride_route_fixture(
    latitude = c(51.50, 51.51, NA, 51.60, 51.61),
    longitude = c(-0.20, -0.19, NA, -0.10, -0.09),
    sample_index = c(5L, 4L, 3L, 2L, 1L)
  )
  prepared <- prepare_latest_ride_route(streams)
  map <- draw_latest_ride_map(streams, "Ride")

  expect_true(prepared$eligible)
  expect_equal(prepared$points$sample_index, c(1L, 2L, 4L, 5L))
  expect_equal(length(prepared$line_segments), 2L)
  expect_equal(sum(leaflet_call_methods(map) == "addPolylines"), 2L)
})

run_test("missing Latest Ride sample rows split route lines", {
  streams <- latest_ride_route_fixture(
    latitude = c(51.50, 51.51, 51.60, 51.61),
    longitude = c(-0.20, -0.19, -0.10, -0.09),
    sample_index = c(1L, 2L, 4L, 5L)
  )
  prepared <- prepare_latest_ride_route(streams)

  expect_true(prepared$eligible)
  expect_equal(length(prepared$line_segments), 2L)
})

run_test("isolated valid route points are shown without a fabricated line", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  streams <- latest_ride_route_fixture(
    latitude = c(51.5, NA, 51.6),
    longitude = c(-0.2, NA, -0.1)
  )
  map <- draw_latest_ride_map(streams, "Ride")
  methods <- leaflet_call_methods(map)

  expect_true("addCircleMarkers" %in% methods)
  expect_true(!"addPolylines" %in% methods)
})

run_test("Latest Ride map eligibility is independent of sport type", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  streams <- latest_ride_route_fixture()
  outdoor <- draw_latest_ride_map(streams, "Ride")
  virtual <- draw_latest_ride_map(streams, "VirtualRide")

  expect_true(inherits(outdoor, "leaflet"))
  expect_true(inherits(virtual, "leaflet"))
  expect_equal(
    sum(leaflet_call_methods(outdoor) == "addPolylines"),
    sum(leaflet_call_methods(virtual) == "addPolylines")
  )
})

tbr_activity_fixture <- function(count = 4L) {
  tibble(
    activity_id = as.character(seq_len(count)),
    activity_name = rep(c("TBR", "Morning Tbr adventure"), length.out = count),
    sport_type = rep("Ride", count),
    gear_id = rep(c("bike-a", "bike-b"), length.out = count),
    start_datetime_local = as.POSIXct(
      "2026-01-01 09:00:00",
      tz = "Europe/London"
    ) +
      (seq_len(count) - 1L) * 86400,
    start_date_local = as.Date("2026-01-01") + seq_len(count) - 1L,
    distance_metres = seq_len(count) * TBR_METRES_PER_MILE,
    moving_time_seconds = seq_len(count) * 600
  )
}

tbr_stream_fixture <- function(activity_id = "1", valid = TRUE) {
  if (valid) {
    tibble(
      activity_id = activity_id,
      sample_index = 1:3,
      latitude = c(51.50, 51.51, 51.52),
      longitude = c(-0.12, -0.11, -0.10)
    )
  } else {
    tibble(
      activity_id = activity_id,
      sample_index = 1:3,
      latitude = c(NA_real_, Inf, 91),
      longitude = c(NA_real_, -0.1, -0.1)
    )
  }
}

run_test("TBR selection is case-insensitive and finds longer names", {
  fixture <- tbr_activity_fixture(4) |>
    dplyr::mutate(
      activity_name = c("TBR", "tbr shops", "Family TbR loop", "Morning ride")
    )
  selected <- select_tbr_activities(fixture)

  expect_equal(selected$activity_id, c("1", "2", "3"))
})

run_test("TBR selection includes only Ride activities", {
  fixture <- tbr_activity_fixture(3) |>
    dplyr::mutate(sport_type = c("Ride", "VirtualRide", "Run"))
  selected <- select_tbr_activities(fixture)

  expect_equal(selected$activity_id, "1")
})

run_test("TBR membership is independent of gear identity", {
  fixture <- tbr_activity_fixture(3) |>
    dplyr::mutate(gear_id = c("usual-bike", "other-bike", NA_character_))

  expect_equal(nrow(select_tbr_activities(fixture)), 3L)
})

run_test("TBR selection is deterministic and one row per activity", {
  fixture <- dplyr::bind_rows(
    tbr_activity_fixture(3),
    tbr_activity_fixture(3)[2, ]
  ) |>
    dplyr::slice(c(4, 3, 1, 2))
  selected <- select_tbr_activities(fixture)

  expect_equal(selected$activity_id, c("1", "2", "3"))
})

run_test("TBR summary includes adventures independently of streams", {
  fixture <- tbr_activity_fixture(3)
  summary <- build_tbr_summary(fixture)

  expect_equal(summary$adventures, 3L)
  expect_equal(summary$distance_miles, 6)
  expect_equal(summary$moving_time_seconds, 3600)
  expect_equal(summary$first_adventure_date, as.Date("2026-01-01"))
  expect_equal(summary$longest_distance_miles, 3)
})

run_test("TBR summary handles missing measurements and empty history", {
  fixture <- tbr_activity_fixture(2) |>
    dplyr::mutate(
      distance_metres = c(NA_real_, TBR_METRES_PER_MILE),
      moving_time_seconds = c(NA_real_, 600)
    )
  summary <- build_tbr_summary(fixture)
  empty <- build_tbr_summary(empty_tbr_activities())

  expect_equal(summary$adventures, 2L)
  expect_equal(summary$distance_miles, 1)
  expect_equal(summary$moving_time_seconds, 600)
  expect_equal(empty$adventures, 0L)
  expect_equal(empty$distance_miles, 0)
  expect_true(is.na(empty$first_adventure_date))
})

run_test("TBR calendar fills months across multiple years", {
  fixture <- tbr_activity_fixture(3) |>
    dplyr::mutate(
      start_datetime_local = as.POSIXct(
        c(
          "2025-12-31 23:30:00",
          "2026-01-01 00:30:00",
          "2026-01-20 10:00:00"
        ),
        tz = "Europe/London"
      ),
      start_date_local = as.Date(c("2025-12-31", "2026-01-01", "2026-01-20")),
      distance_metres = c(1, 2, 3) * TBR_METRES_PER_MILE
    )
  calendar <- build_tbr_calendar(fixture, as.Date("2026-03-15"))
  january <- dplyr::filter(calendar, .data$year == 2026, .data$month == 1)
  february <- dplyr::filter(calendar, .data$year == 2026, .data$month == 2)
  april <- dplyr::filter(calendar, .data$year == 2026, .data$month == 4)

  expect_equal(nrow(calendar), 24L)
  expect_equal(january$adventures, 2L)
  expect_equal(january$distance_miles, 5)
  expect_equal(february$adventures, 0L)
  expect_true(!february$is_future)
  expect_true(april$is_future)
})

run_test("TBR calendar has an explicit empty model", {
  expect_equal(nrow(build_tbr_calendar(empty_tbr_activities())), 0L)
})

run_test("TBR milestones use stable activity ordering", {
  fixture <- tbr_activity_fixture(10) |>
    dplyr::mutate(
      start_datetime_local = as.POSIXct(
        "2026-02-01 10:00:00",
        tz = "Europe/London"
      ),
      start_date_local = as.Date("2026-02-01"),
      activity_id = as.character(rev(seq_len(10)))
    )
  first <- build_tbr_milestones(fixture)
  second <- build_tbr_milestones(dplyr::slice_sample(fixture, prop = 1))

  expect_equal(first, second)
  expect_true("10 adventures together" %in% first$label)
})

run_test("TBR mileage milestones use the first exact threshold crossing", {
  fixture <- tbr_activity_fixture(3) |>
    dplyr::mutate(distance_metres = c(40, 60, 200) * TBR_METRES_PER_MILE)
  milestones <- build_tbr_milestones(fixture)
  hundred <- dplyr::filter(milestones, .data$label == "100 miles together")
  two_fifty <- dplyr::filter(milestones, .data$label == "250 miles together")

  expect_equal(hundred$milestone_date, as.Date("2026-01-02"))
  expect_equal(two_fifty$milestone_date, as.Date("2026-01-03"))
  expect_true(!"500 miles together" %in% milestones$label)
})

run_test("TBR longest and most-active month rules are deterministic", {
  fixture <- tbr_activity_fixture(4) |>
    dplyr::mutate(
      start_datetime_local = as.POSIXct(
        c(
          "2026-01-01 10:00:00",
          "2026-01-02 10:00:00",
          "2026-02-01 10:00:00",
          "2026-02-02 10:00:00"
        ),
        tz = "Europe/London"
      ),
      start_date_local = as.Date(c(
        "2026-01-01",
        "2026-01-02",
        "2026-02-01",
        "2026-02-02"
      )),
      distance_metres = c(5, 5, 4, 7) * TBR_METRES_PER_MILE
    )
  milestones <- build_tbr_milestones(fixture)

  expect_true(any(grepl(
    "Longest adventure — 7.0 miles",
    milestones$label,
    fixed = TRUE
  )))
  expect_true(any(grepl(
    "Most active month — February 2026",
    milestones$label,
    fixed = TRUE
  )))
})

run_test("TBR route preparation excludes invalid and degenerate geometry", {
  invalid <- prepare_tbr_route(tbr_stream_fixture(valid = FALSE))
  repeated <- prepare_tbr_route(tibble(
    activity_id = "1",
    sample_index = 1:3,
    latitude = rep(51.5, 3),
    longitude = rep(-0.1, 3)
  ))

  expect_true(!invalid$eligible)
  expect_true(!repeated$eligible)
})

run_test("TBR route preparation does not bridge missing coordinates", {
  streams <- tibble(
    activity_id = "1",
    sample_index = 1:5,
    latitude = c(51.50, 51.51, NA, 51.60, 51.61),
    longitude = c(-0.20, -0.19, NA, -0.10, -0.09)
  )
  prepared <- prepare_tbr_route(streams)

  expect_true(prepared$eligible)
  expect_equal(length(prepared$line_segments), 2L)
})

run_test("TBR map model highlights latest mapped rather than latest activity", {
  activities <- tbr_activity_fixture(3)
  streams <- dplyr::bind_rows(tbr_stream_fixture("1"), tbr_stream_fixture("2"))
  model <- build_tbr_map_model(activities, streams)

  expect_equal(model$latest_mapped_activity_id, "2")
  expect_equal(model$unmapped, 1L)
})

tbr_representative_fixture <- function() {
  tibble(
    activity_id = as.character(1:7),
    start_datetime_local = as.POSIXct("2026-01-01", tz = "Europe/London") +
      seq_len(7) * 86400,
    latitude = c(51.50, 51.52, 44.00, 44.04, 53.00, 53.03, 40.00),
    longitude = c(-0.10, -0.12, -1.00, -1.03, -2.00, -2.02, 10.00)
  )
}

run_test("TBR focus discovery finds local holiday and future-home areas", {
  focus <- discover_tbr_focus_areas(
    tbr_representative_fixture(),
    latest_mapped_activity_id = "7"
  )
  assignments <- focus$assignments

  expect_equal(
    nrow(dplyr::filter(focus$controls, .data$control_type == "area")),
    3L
  )
  expect_equal(
    assignments$cluster_id[assignments$activity_id == "1"],
    assignments$cluster_id[assignments$activity_id == "2"]
  )
  expect_equal(
    assignments$cluster_id[assignments$activity_id == "3"],
    assignments$cluster_id[assignments$activity_id == "4"]
  )
  expect_equal(
    assignments$cluster_id[assignments$activity_id == "5"],
    assignments$cluster_id[assignments$activity_id == "6"]
  )
  expect_true(
    length(unique(assignments$cluster_id[
      assignments$activity_id %in% c("1", "3", "5")
    ])) ==
      3L
  )
})

run_test("TBR focus membership is independent of input order", {
  fixture <- tbr_representative_fixture()
  first <- discover_tbr_focus_areas(
    fixture,
    latest_mapped_activity_id = "7"
  )$assignments |>
    dplyr::select("activity_id", "cluster_id", "control_type", "control_label")
  second <- discover_tbr_focus_areas(
    dplyr::slice_sample(fixture, prop = 1),
    latest_mapped_activity_id = "7"
  )$assignments |>
    dplyr::select("activity_id", "cluster_id", "control_type", "control_label")

  expect_equal(first, second)
})

run_test("TBR focus controls cap isolated one-off adventures", {
  isolated <- tibble(
    activity_id = as.character(1:8),
    start_datetime_local = as.POSIXct("2026-01-01", tz = "Europe/London") +
      seq_len(8) * 86400,
    latitude = seq(10, 80, by = 10),
    longitude = seq(-140, 140, length.out = 8)
  )
  focus <- discover_tbr_focus_areas(
    isolated,
    max_outlier_controls = 3L,
    latest_mapped_activity_id = "8"
  )

  expect_equal(nrow(focus$controls), 3L)
  expect_true(all(focus$controls$control_type == "outlier"))
  expect_equal(sum(is.na(focus$assignments$control_type)), 5L)
})

run_test("TBR clustering distance parameter has predictable effects", {
  nearby <- tibble(
    activity_id = c("1", "2"),
    start_datetime_local = as.POSIXct(c("2026-01-01", "2026-01-02")),
    latitude = c(51.5, 51.5),
    longitude = c(-0.1, 0.2)
  )
  narrow <- discover_tbr_focus_areas(
    nearby,
    distance_km = 15,
    max_outlier_controls = 0L
  )
  broad <- discover_tbr_focus_areas(
    nearby,
    distance_km = 30,
    max_outlier_controls = 0L
  )

  expect_equal(nrow(narrow$controls), 0L)
  expect_equal(nrow(broad$controls), 1L)
  expect_true(all(broad$assignments$control_type == "area"))
})

run_test("TBR route start representative prevents long-route cluster bridging", {
  activities <- tbr_activity_fixture(3) |>
    dplyr::mutate(
      start_datetime_local = as.POSIXct(c(
        "2026-01-01",
        "2026-01-02",
        "2026-01-03"
      )),
      start_date_local = as.Date(c("2026-01-01", "2026-01-02", "2026-01-03"))
    )
  streams <- dplyr::bind_rows(
    tibble(
      activity_id = "1",
      sample_index = 1:3,
      latitude = c(51.50, 48.00, 44.00),
      longitude = c(-0.10, -0.50, -1.00)
    ),
    tibble(
      activity_id = "2",
      sample_index = 1:2,
      latitude = c(51.51, 51.52),
      longitude = c(-0.11, -0.12)
    ),
    tibble(
      activity_id = "3",
      sample_index = 1:2,
      latitude = c(44.01, 44.02),
      longitude = c(-1.01, -1.02)
    )
  )
  model <- build_tbr_map_model(activities, streams)
  focus <- discover_tbr_focus_areas(
    model$representatives,
    min_cluster_size = 2L,
    max_outlier_controls = 0L,
    latest_mapped_activity_id = model$latest_mapped_activity_id
  )

  expect_equal(
    model$representatives$latitude[model$representatives$activity_id == "1"],
    51.50
  )
  expect_equal(nrow(focus$controls), 1L)
  expect_equal(
    focus$assignments$cluster_id[focus$assignments$activity_id == "1"],
    focus$assignments$cluster_id[focus$assignments$activity_id == "2"]
  )
})

run_test("invalid TBR routes do not determine focus areas", {
  activities <- tbr_activity_fixture(2)
  streams <- dplyr::bind_rows(
    tbr_stream_fixture("1"),
    tbr_stream_fixture("2", FALSE)
  )
  model <- build_tbr_map_model(activities, streams)

  expect_equal(model$representatives$activity_id, "1")
  expect_equal(names(model$routes), "1")
})

run_test("TBR viewports contain latest focus and all route geometry", {
  activities <- tbr_activity_fixture(4)
  streams <- dplyr::bind_rows(
    tbr_stream_fixture("1"),
    tbr_stream_fixture("2") |>
      dplyr::mutate(latitude = .data$latitude + 0.02),
    tbr_stream_fixture("3") |>
      dplyr::mutate(
        latitude = .data$latitude - 7,
        longitude = .data$longitude - 1
      ),
    tbr_stream_fixture("4") |>
      dplyr::mutate(
        latitude = .data$latitude - 7.02,
        longitude = .data$longitude - 1.02
      )
  )
  model <- build_tbr_map_model(activities, streams)
  latest <- dplyr::filter(model$viewports, .data$kind == "latest")
  all <- dplyr::filter(model$viewports, .data$kind == "all")
  areas <- dplyr::filter(model$viewports, .data$kind == "area")

  expect_equal(model$viewports$label[[1]], "Latest")
  expect_equal(latest$max_zoom, TBR_FOCUS_LATEST_MAX_ZOOM)
  expect_equal(all$max_zoom, TBR_FOCUS_ALL_MAX_ZOOM)
  expect_equal(nrow(areas), 2L)
  expect_true(latest$south <= min(streams$latitude[streams$activity_id == "4"]))
  expect_true(latest$north >= max(streams$latitude[streams$activity_id == "4"]))
  expect_true(all$south <= min(streams$latitude))
  expect_true(all$north >= max(streams$latitude))
  expect_true(all$west <= min(streams$longitude))
  expect_true(all$east >= max(streams$longitude))
  for (area_label in areas$label) {
    assigned_ids <- model$focus_areas$assignments |>
      dplyr::filter(.data$control_label == area_label) |>
      dplyr::pull(.data$activity_id)
    assigned_geometry <- dplyr::filter(
      streams,
      as.character(.data$activity_id) %in% assigned_ids
    )
    viewport <- dplyr::filter(areas, .data$label == area_label)
    expect_true(viewport$south <= min(assigned_geometry$latitude))
    expect_true(viewport$north >= max(assigned_geometry$latitude))
    expect_true(viewport$west <= min(assigned_geometry$longitude))
    expect_true(viewport$east >= max(assigned_geometry$longitude))
  }
})

run_test("single isolated TBR adventure remains available through Latest", {
  model <- build_tbr_map_model(
    tbr_activity_fixture(1),
    tbr_stream_fixture("1")
  )

  expect_equal(model$viewports$label, c("Latest", "All adventures"))
  expect_equal(model$latest_mapped_activity_id, "1")
})

run_test("TBR locality labels prefer broad recognisable places", {
  expect_equal(
    tbr_locality_label(
      tibble(
        borough = "Richmond upon Thames",
        town = "London",
        city = "London"
      ),
      "Area 1"
    ),
    "Richmond upon Thames"
  )
  expect_equal(
    tbr_locality_label(
      tibble(
        borough = NA_character_,
        municipality = "Mimizan",
        town = "Parentis-en-Born"
      ),
      "Area 2"
    ),
    "Mimizan"
  )
  expect_equal(
    tbr_locality_label(
      tibble(
        borough = NA_character_,
        municipality = NA_character_,
        town = "Parentis-en-Born"
      ),
      "Area 2"
    ),
    "Parentis-en-Born"
  )
  expect_equal(
    tbr_locality_label(
      tibble(suburb = "A small suburb", hamlet = "A tiny hamlet"),
      "Area 3"
    ),
    "Area 3"
  )
})

run_test("duplicate TBR locality labels are deterministic and distinguishable", {
  expect_equal(
    disambiguate_tbr_locality_labels(c("London", "Mimizan", "London")),
    c("London (1)", "Mimizan", "London (2)")
  )
})

run_test("TBR focus geocoding uses median member starts without changing clusters", {
  fixture <- tbr_representative_fixture()
  focus <- discover_tbr_focus_areas(
    fixture,
    latest_mapped_activity_id = "7"
  )
  model <- list(
    routes = list(),
    latest_mapped_activity_id = "7",
    representatives = fixture,
    focus_areas = focus,
    viewports = tibble()
  )
  positions <- tbr_focus_area_representatives(focus, fixture)
  before <- focus$assignments |>
    dplyr::select("activity_id", "cluster_id")
  cache <- new.env(parent = emptyenv())
  calls <- 0L
  geocoder <- function(locations) {
    calls <<- calls + 1L
    places <- c("London", "Mimizan", "Manchester")
    dplyr::bind_cols(
      locations,
      tibble(borough = places[seq_len(nrow(locations))])
    )
  }

  labelled <- label_tbr_focus_areas(model, geocoder = geocoder, cache = cache)
  labelled_again <- label_tbr_focus_areas(
    model,
    geocoder = geocoder,
    cache = cache
  )

  expect_equal(positions$latitude, c(51.51, 44.02, 53.015))
  expect_equal(positions$longitude, c(-0.11, -1.015, -2.01))
  expect_equal(
    labelled$focus_areas$assignments |>
      dplyr::select("activity_id", "cluster_id"),
    before
  )
  expect_equal(
    labelled$focus_areas$controls$control_label,
    c("London", "Mimizan", "Manchester")
  )
  expect_equal(
    labelled_again$focus_areas$controls$control_label,
    labelled$focus_areas$controls$control_label
  )
  expect_equal(calls, 1L)
})

run_test("TBR focus locality failure preserves generic labels and viewport bounds", {
  activities <- tbr_activity_fixture(4)
  streams <- dplyr::bind_rows(
    tbr_stream_fixture("1"),
    tbr_stream_fixture("2") |> dplyr::mutate(latitude = .data$latitude + 0.02),
    tbr_stream_fixture("3") |>
      dplyr::mutate(
        latitude = .data$latitude - 7,
        longitude = .data$longitude - 1
      ),
    tbr_stream_fixture("4") |>
      dplyr::mutate(
        latitude = .data$latitude - 7.02,
        longitude = .data$longitude - 1.02
      )
  )
  model <- build_tbr_map_model(activities, streams)
  warnings <- character()
  labelled <- label_tbr_focus_areas(
    model,
    geocoder = function(...) stop("Could not resolve host", call. = FALSE),
    cache = new.env(parent = emptyenv()),
    warn = function(message, ...) warnings <<- c(warnings, message)
  )

  expect_equal(
    labelled$focus_areas$controls$control_label,
    model$focus_areas$controls$control_label
  )
  expect_equal(
    dplyr::select(labelled$viewports, -"label"),
    dplyr::select(model$viewports, -"label")
  )
  expect_equal(length(warnings), 1L)
  expect_true(grepl("generic area labels", warnings[[1]], fixed = TRUE))
  expect_true(!grepl("51.", warnings[[1]], fixed = TRUE))
})

run_test("TBR map renders geocoded focus labels without changing route layers", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  map <- draw_tbr_adventure_map(
    tbr_activity_fixture(2),
    dplyr::bind_rows(tbr_stream_fixture("1"), tbr_stream_fixture("2")),
    geocoder = function(locations) {
      dplyr::bind_cols(
        locations,
        tibble(borough = rep("Richmond upon Thames", nrow(locations)))
      )
    },
    geocode_cache = new.env(parent = emptyenv())
  )
  methods <- leaflet_call_methods(map)

  expect_equal(sum(methods == "addPolylines"), 2L)
  expect_true(any(vapply(
    map$jsHooks$render[[1]]$data$viewports,
    function(viewport) identical(viewport$label, "Richmond upon Thames"),
    logical(1)
  )))
})

run_test("TBR map renders historical and highlighted route presentation", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  activities <- tbr_activity_fixture(2)
  streams <- dplyr::bind_rows(tbr_stream_fixture("1"), tbr_stream_fixture("2"))
  map <- draw_tbr_adventure_map(
    activities,
    streams,
    geocode_focus_labels = FALSE
  )
  methods <- leaflet_call_methods(map)
  lines <- map$x$calls[methods == "addPolylines"]
  colours <- vapply(lines, function(call) call$args[[4]]$color, character(1))
  weights <- vapply(lines, function(call) call$args[[4]]$weight, numeric(1))
  control <- map$x$calls[[which(methods == "addControl")]]$args[[1]]
  latest_popup <- lines[[2]]$args[[5]]

  expect_true(inherits(map, "leaflet"))
  expect_true(grepl(
    "rastertiles/voyager_labels_under",
    map$x$calls[[1]]$args[[1]],
    fixed = TRUE
  ))
  expect_equal(colours, c(TBR_HISTORICAL_ROUTE_COLOR, TBR_LATEST_ROUTE_COLOR))
  expect_equal(weights, c(TBR_HISTORICAL_ROUTE_WEIGHT, TBR_LATEST_ROUTE_WEIGHT))
  expect_equal(
    vapply(lines, function(call) call$args[[4]]$opacity, numeric(1)),
    c(TBR_HISTORICAL_ROUTE_OPACITY, TBR_LATEST_ROUTE_OPACITY)
  )
  expect_true(grepl("tbr-2-", lines[[length(lines)]]$args[[2]], fixed = TRUE))
  expect_true(grepl("Latest mapped adventure", control, fixed = TRUE))
  expect_true(grepl(
    "https://www.strava.com/activities/2",
    latest_popup,
    fixed = TRUE
  ))
  expect_equal(sum(methods == "addPolylines"), 2L)
  expect_true(length(map$jsHooks$render) == 1L)
  hook <- map$jsHooks$render[[1]]
  expect_true(grepl("fitBounds", hook$code, fixed = TRUE))
  expect_true(grepl("tbr-focus-control", hook$code, fixed = TRUE))
  expect_true(!grepl("removeLayer", hook$code, fixed = TRUE))
  expect_equal(hook$data$viewports[[1]]$label, "Latest")
  expect_equal(tail(hook$data$viewports, 1)[[1]]$label, "All adventures")
  expect_equal(hook$data$padding, TBR_FOCUS_VIEWPORT_PADDING_PX)
})

run_test("TBR focus controls survive static widget serialization", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  map <- draw_tbr_adventure_map(
    tbr_activity_fixture(2),
    dplyr::bind_rows(tbr_stream_fixture("1"), tbr_stream_fixture("2")),
    geocode_focus_labels = FALSE
  )
  output <- tempfile(fileext = ".html")
  htmlwidgets::saveWidget(map, output, selfcontained = FALSE)
  rendered <- paste(readLines(output, warn = FALSE), collapse = "\n")

  expect_true(grepl("tbr-focus-control", rendered, fixed = TRUE))
  expect_true(grepl("All adventures", rendered, fixed = TRUE))
  expect_true(grepl("fitBounds", rendered, fixed = TRUE))
})

run_test("TBR popup escapes activity names and preserves metadata", {
  activity <- tbr_activity_fixture(1) |>
    dplyr::mutate(activity_name = "TBR <script>alert(1)</script>")
  popup <- tbr_route_popup(activity)

  expect_true(!grepl("<script>", popup, fixed = TRUE))
  expect_true(grepl("&lt;script&gt;", popup, fixed = TRUE))
  expect_true(grepl("1.0 miles", popup, fixed = TRUE))
  expect_true(grepl("https://www.strava.com/activities/1", popup, fixed = TRUE))
})

run_test("TBR map has clear empty and no-GPS states", {
  no_history <- draw_tbr_adventure_map(
    empty_tbr_activities(),
    empty_tbr_position_streams()
  )
  no_gps <- draw_tbr_adventure_map(
    tbr_activity_fixture(1),
    empty_tbr_position_streams()
  )

  expect_true(grepl(
    "No family adventures",
    as.character(no_history),
    fixed = TRUE
  ))
  expect_true(grepl(
    "none currently has usable route",
    as.character(no_gps),
    fixed = TRUE
  ))
})

run_test("a qualifying Latest Ride remains usable without streams", {
  selected <- select_latest_significant_activity(
    latest_ride_fixture |> dplyr::slice(2)
  ) |>
    dplyr::mutate(activity_name = "Fixture ride")
  availability <- latest_ride_stream_availability(empty_latest_ride_streams())
  expect_equal(nrow(selected), 1L)
  expect_true(all(!availability))
  identity <- latest_ride_identity(selected)
  identity_html <- as.character(identity)
  expect_true(inherits(identity, "shiny.tag"))
  expect_true(grepl("Fixture ride", identity_html, fixed = TRUE))
  expect_true(grepl(
    "Wednesday 22 July 2026, 08:00",
    identity_html,
    fixed = TRUE
  ))
  expect_true(grepl(
    "https://www.strava.com/activities/2",
    identity_html,
    fixed = TRUE
  ))
})

run_test("Latest Ride HR zones use an explicit configured maximum", {
  zone_streams <- tibble(heartrate_bpm = c(100, 120, 140, 160, 180))
  zones <- build_latest_ride_hr_zones(zone_streams, max_hr_bpm = 200)
  expect_equal(as.character(zones$zone), paste0("Z", 1:5))
  expect_equal(sum(zones$seconds), 5)
  expect_equal(
    nrow(build_latest_ride_hr_zones(zone_streams, max_hr_bpm = NA_real_)),
    0L
  )
})

run_test("Latest Ride highlights favour activity and strong power rankings", {
  rankings <- tibble(
    achievement_rank = c(4, 2, 1, 12),
    comparison_count = c(100, 20, 100, 100),
    ranking_type = c("distance", "speed_50_miles", "power", "power"),
    duration_seconds = c(0, 0, 1800, 300),
    metric_value = c(200000, 20, 230, 250)
  )
  rendered <- as.character(latest_ride_highlights(rankings))
  expect_true(grepl("4th longest ride this year", rendered, fixed = TRUE))
  expect_true(grepl(
    "2nd fastest 50+ mile ride this year",
    rendered,
    fixed = TRUE
  ))
  expect_true(grepl("1st best 30 min power this year", rendered, fixed = TRUE))
  expect_true(!grepl("12th", rendered, fixed = TRUE))
})

inspector_activity_fixture <- function(activity_id = "123") {
  tibble(
    activity_id = activity_id,
    activity_name = "Unfamiliar coastal ride",
    sport_type = "Ride",
    activity_type = "Ride",
    timezone_name = "Europe/London",
    start_datetime_utc = as.POSIXct("2026-08-01 07:00:00", tz = "UTC"),
    start_datetime_local = as.POSIXct(
      "2026-08-01 08:00:00",
      tz = "Europe/London"
    ),
    start_date_local = as.Date("2026-08-01"),
    start_time_local = "08:00:00",
    distance_metres = 10000,
    moving_time_seconds = 1800L,
    elapsed_time_seconds = 2000L,
    elevation_gain_metres = 100,
    has_streams = TRUE,
    transformed_at = as.POSIXct("2026-08-02", tz = "UTC")
  )
}

inspector_stream_fixture <- function(
  sample_index = 1:6,
  latitude = 51.5 + seq_along(sample_index) / 1000,
  longitude = -0.1 + seq_along(sample_index) / 1000
) {
  tibble(
    activity_id = "123",
    sample_index = as.integer(sample_index),
    time_seconds = c(0, 1, 1, 3, NA, 5)[seq_along(sample_index)],
    distance_metres = seq_along(sample_index) * 10,
    latitude = latitude,
    longitude = longitude,
    altitude_metres = 20 + seq_along(sample_index),
    velocity_smooth_metres_per_second = 5,
    heartrate_bpm = NA_integer_,
    cadence_rpm = 80L,
    watts = 180L,
    temperature_celsius = NA_integer_,
    is_moving = TRUE,
    grade_smooth_percent = 1
  )
}

run_test("Activity Inspector validates activity IDs", {
  expect_equal(validate_inspector_activity_id(" 123456 "), "123456")
  expect_error(validate_inspector_activity_id("12x"), "digits only")
  expect_error(validate_inspector_activity_id(""), "digits only")
  expect_error(validate_inspector_activity_id(c("1", "2")), "digits only")
})

run_test("Activity Inspector uses parameterised activity-scoped SELECT queries", {
  calls <- list()
  query <- function(connection, statement, params) {
    calls[[length(calls) + 1L]] <<- list(statement = statement, params = params)
    data.frame()
  }
  fetch_inspector_activity(NULL, "123", get_query = query)
  fetch_inspector_streams(NULL, "123", get_query = query)

  expect_true(all(vapply(
    calls,
    function(call) grepl("WHERE activity_id = ?", call$statement, fixed = TRUE),
    logical(1)
  )))
  expect_true(all(vapply(
    calls,
    function(call) identical(call$params, list("123")),
    logical(1)
  )))
  expect_true(grepl(
    "ORDER BY sample_index",
    calls[[2]]$statement,
    fixed = TRUE
  ))
  expect_true(all(
    !grepl(
      "INSERT|UPDATE|DELETE",
      vapply(calls, `[[`, character(1), "statement"),
      ignore.case = TRUE
    )
  ))
})

run_test("Activity Inspector closes its connection and handles a missing activity", {
  disconnected <- FALSE
  query_count <- 0L
  result <- load_inspector_activity(
    "123",
    connection_factory = function() {
      structure(list(), class = "fixture_connection")
    },
    disconnect = function(connection) disconnected <<- TRUE,
    get_query = function(connection, statement, params) {
      query_count <<- query_count + 1L
      data.frame()
    }
  )

  expect_true(disconnected)
  expect_equal(query_count, 1L)
  expect_equal(nrow(result$activity), 0L)
  expect_equal(nrow(result$streams), 0L)
})

run_test("Activity Inspector preserves missing fields and duplicate elapsed times", {
  streams <- inspector_stream_fixture() |>
    dplyr::select(
      "activity_id",
      "sample_index",
      "time_seconds",
      "latitude",
      "longitude"
    )
  model <- prepare_inspection_model(inspector_activity_fixture(), streams)

  expect_equal(model$streams$sample_index, 1:6)
  expect_equal(model$streams$time_seconds[2:3], c(1, 1))
  expect_true(all(is.na(model$streams$watts)))
  expect_equal(nrow(model$metrics), 0L)
})

run_test("Activity Inspector preserves an activity with no stream rows", {
  model <- prepare_inspection_model(inspector_activity_fixture(), data.frame())

  expect_equal(nrow(model$activity), 1L)
  expect_equal(nrow(model$streams), 0L)
  expect_equal(length(model$route$segments), 0L)
  expect_equal(nrow(model$metrics), 0L)
})

run_test("Activity Inspector splits routes at invalid coordinates and index gaps", {
  streams <- inspector_stream_fixture(
    sample_index = c(1L, 2L, 4L, 5L, 6L, 7L),
    latitude = c(51.50, 51.51, 51.52, NA, 51.54, 91),
    longitude = c(-0.10, -0.09, -0.08, -0.07, -0.06, -0.05)
  )
  route <- prepare_inspector_route(streams)

  expect_equal(length(route$segments), 1L)
  expect_equal(route$segments[[1]]$sample_index, c(1L, 2L))
  expect_equal(route$points$sample_index, c(1L, 2L, 4L, 6L))
})

run_test("Activity Inspector retains repeated coordinates and reports spatial ambiguity", {
  streams <- inspector_stream_fixture(
    latitude = c(51.5, 51.5, 51.51, 51.52, 51.53, 51.54),
    longitude = c(-0.1, -0.1, -0.09, -0.08, -0.07, -0.06)
  )
  model <- prepare_inspection_model(inspector_activity_fixture(), streams)
  nearest <- nearest_inspector_sample(model, 51.5, -0.1)

  expect_equal(nearest$sample_index, 1L)
  expect_true(nearest$ambiguous)
  expect_equal(nearest$candidate_indices, c(1L, 2L))
})

run_test("Activity Inspector range selection is inclusive and gap-aware", {
  model <- prepare_inspection_model(
    inspector_activity_fixture(),
    inspector_stream_fixture(sample_index = c(10L, 20L, 30L, 40L, 50L, 60L))
  )
  selected <- inspector_range_streams(model, 20L, 50L)

  expect_equal(selected$sample_index, c(20L, 30L, 40L, 50L))
  expect_equal(inspector_neighbour_index(model, 30L, "previous"), 20L)
  expect_equal(inspector_neighbour_index(model, 30L, "next"), 40L)
  expect_error(validate_inspector_range(model, 50L, 20L), "must not exceed")
  expect_error(validate_inspector_range(model, 21L, 50L), "existing canonical")
})

run_test("Activity Inspector permits missing-GPS boundaries and formats clipboard output", {
  streams <- inspector_stream_fixture()
  streams$latitude[c(2, 5)] <- NA_real_
  streams$longitude[c(2, 5)] <- NA_real_
  model <- prepare_inspection_model(inspector_activity_fixture(), streams)

  expect_equal(nrow(inspector_range_streams(model, 2L, 5L)), 4L)
  expect_equal(
    inspector_clipboard_text(model, 2L, 5L),
    "ride_start_sample_index = 2\nride_end_sample_index = 5"
  )
})

run_test("Activity Inspector map and timeline preserve canonical sample identity", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  model <- prepare_inspection_model(
    inspector_activity_fixture(),
    inspector_stream_fixture()
  )
  map <- build_inspector_map(model)
  timeline <- build_inspector_timeline(
    model,
    "distance_metres",
    current_index = 4L
  )
  built_timeline <- plotly::plotly_build(timeline)
  map_methods <- leaflet_call_methods(map)

  expect_true("addPolylines" %in% map_methods)
  expect_equal(
    as.integer(built_timeline$x$data[[1]]$customdata),
    model$streams$sample_index
  )
  expect_equal(built_timeline$x$data[[1]]$type, "scattergl")
  expect_equal(built_timeline$x$layout$shapes[[1]]$x0, 4L)
})

run_test("Activity Inspector handles forty thousand full-resolution samples", {
  sample_count <- 40000L
  streams <- tibble(
    activity_id = "123",
    sample_index = seq_len(sample_count),
    time_seconds = seq_len(sample_count) - 1L,
    distance_metres = seq_len(sample_count) * 5,
    latitude = 51.5 + seq_len(sample_count) / 1e7,
    longitude = -0.1 + seq_len(sample_count) / 1e7,
    altitude_metres = 20 + sin(seq_len(sample_count) / 100),
    watts = 180L
  )
  elapsed <- system.time({
    model <- prepare_inspection_model(inspector_activity_fixture(), streams)
    timeline <- build_inspector_timeline(model, "distance_metres")
    built_timeline <- plotly::plotly_build(timeline)
  })[["elapsed"]]

  expect_equal(nrow(model$streams), sample_count)
  expect_equal(nrow(model$route$points), sample_count)
  expect_equal(built_timeline$x$data[[1]]$type, "scattergl")
  expect_true(elapsed < 5)
})

run_test("Activity Inspector server supports load inspect and boundary workflow", {
  withr::local_envvar(CARTO_BASEMAP_API_KEY = "test-carto-key")
  app_environment <- new.env(parent = globalenv())
  sys.source("apps/activity-inspector/app.R", envir = app_environment)
  fixture_loader <- function(activity_id) {
    list(
      activity = inspector_activity_fixture(activity_id),
      streams = inspector_stream_fixture() |>
        dplyr::mutate(activity_id = activity_id)
    )
  }

  server_under_test <- function(input, output, session) {
    state <- app_environment$activity_inspector_server(
      input,
      output,
      session,
      loader = fixture_loader
    )
  }

  shiny::testServer(
    server_under_test,
    {
      session$setInputs(activity_id = "123", load_activity = 1)
      session$flushReact()
      expect_equal(state$current_index, 1L)
      expect_equal(nrow(state$model$streams), 6L)

      session$setInputs(
        activity_map_shape_click = list(lat = 51.504, lng = -0.096)
      )
      session$flushReact()
      expect_equal(state$current_index, 4L)

      session$setInputs(set_start = 1)
      session$setInputs(current_next = 1)
      session$setInputs(set_end = 1)
      session$flushReact()
      expect_equal(state$start_index, 4L)
      expect_equal(state$end_index, 5L)

      session$setInputs(end_previous = 1)
      session$flushReact()
      expect_equal(state$end_index, 4L)
    }
  )
})

run_test("missing database configuration fails before connection retries", {
  database_keys <- c(
    "MARIADB_HOST",
    "MARIADB_PORT",
    "MARIADB_NAME",
    "MARIADB_USER",
    "MARIADB_PASSWORD"
  )
  old_values <- Sys.getenv(database_keys, unset = NA_character_)
  on.exit(
    {
      Sys.unsetenv(database_keys)
      present <- !is.na(old_values)
      if (any(present)) {
        do.call(
          Sys.setenv,
          as.list(stats::setNames(old_values[present], database_keys[present]))
        )
      }
    },
    add = TRUE
  )

  Sys.unsetenv(database_keys)
  expect_error(
    get_database_config(),
    "Missing required database configuration"
  )

  Sys.setenv(
    MARIADB_HOST = "database",
    MARIADB_PORT = "not-a-port",
    MARIADB_NAME = "cycling",
    MARIADB_USER = "reader",
    MARIADB_PASSWORD = "test-only"
  )
  expect_error(
    get_database_config(),
    "MARIADB_PORT must be an integer between 1 and 65535."
  )
})

coaching_lap_fixture <- function(
  power_ratio,
  elevation_gain = 0,
  vam = 0,
  duration = 1200,
  telemetry = TRUE,
  names = paste("Lap", seq_along(power_ratio))
) {
  count <- length(power_ratio)
  tibble(
    lap_id = seq_len(count),
    activity_id = 1,
    lap_index = seq_len(count),
    effort_name = names,
    elapsed_time_seconds = duration,
    moving_time_seconds = duration,
    distance_metres = duration * 8,
    start_sample_index = seq(1, by = 2000, length.out = count),
    end_sample_index = start_sample_index + duration - 1,
    start_time_seconds = seq(0, by = 2000, length.out = count),
    end_time_seconds = start_time_seconds + duration,
    start_distance_metres = seq(0, by = 10000, length.out = count),
    end_distance_metres = start_distance_metres + distance_metres,
    average_speed_miles_per_hour = 18,
    average_cadence_rpm = 85,
    average_power_watts = 180 * power_ratio,
    normalized_power_watts = NA_real_,
    average_heartrate_bpm = 145,
    elevation_gain_metres = elevation_gain,
    vam_metres_per_hour = vam,
    net_elevation_change_metres = elevation_gain,
    telemetry_sample_count = ifelse(telemetry, duration, 0),
    telemetry_available = telemetry,
    ride_average_power_watts = 180,
    power_ratio = power_ratio
  )
}

run_test("interval ride selects several coaching efforts", {
  laps <- coaching_lap_fixture(
    c(0.75, 1.30, 0.55, 1.25, 0.55, 1.20, 0.70),
    names = c(
      "Warm up",
      "Interval 1",
      "Recovery",
      "Interval 2",
      "Recovery 2",
      "Threshold",
      "Cool down"
    )
  )
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, c("Interval 1", "Interval 2", "Threshold"))
})

run_test("mountain ride selects principal climbs without duplicates", {
  laps <- coaching_lap_fixture(
    power_ratio = c(0.95, 0.90, 1.02),
    elevation_gain = c(420, 20, 280),
    vam = c(720, 80, 650),
    duration = c(2100, 600, 1500),
    names = c("Long climb", "Descent", "Steep climb")
  )
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, c("Long climb", "Steep climb"))
  expect_equal(length(unique(selected$lap_id)), nrow(selected))
})

run_test("steady endurance ride selects no individual efforts", {
  laps <- coaching_lap_fixture(rep(1, 6), duration = rep(3600, 6))
  expect_equal(nrow(select_coaching_efforts(laps)), 0L)
})

run_test("incomplete lap telemetry degrades without selecting an effort", {
  laps <- coaching_lap_fixture(c(1.35, 1.25), telemetry = c(FALSE, TRUE))
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$lap_id, 2L)
})

run_test("many high-quality laps are limited to five effort pages", {
  laps <- coaching_lap_fixture(seq(1.15, 1.42, length.out = 10))
  selected <- select_coaching_efforts(laps)

  expect_equal(nrow(selected), 5L)
  expect_equal(length(unique(selected$lap_id)), 5L)
})

run_test("coherent work sets retain every recovery-separated effort", {
  work_ratios <- c(1.42, 1.46, 1.49, 1.47, 1.48, 1.48, 1.48, 1.47)
  ratios <- as.vector(rbind(work_ratios, rep(0.65, length(work_ratios))))
  durations <- as.vector(rbind(
    c(219, 121, 334, 194, 193, 517, 191, 309),
    rep(180, length(work_ratios))
  ))
  names <- as.vector(rbind(
    paste("Work", seq_along(work_ratios)),
    paste("Recovery", seq_along(work_ratios))
  ))
  laps <- coaching_lap_fixture(ratios, duration = durations, names = names)
  selected <- select_coaching_efforts(laps)

  expect_equal(selected$effort_name, paste("Work", seq_along(work_ratios)))
})

run_test("coherent work sets respect the ten-effort hard ceiling", {
  work_count <- 12L
  ratios <- as.vector(rbind(rep(1.35, work_count), rep(0.65, work_count)))
  names <- as.vector(rbind(
    paste("Work", seq_len(work_count)),
    paste("Recovery", seq_len(work_count))
  ))
  laps <- coaching_lap_fixture(ratios, duration = 240, names = names)
  selected <- select_coaching_efforts(laps)

  expect_equal(nrow(selected), 10L)
  expect_equal(selected$effort_name, paste("Work", seq_len(10)))
})

run_test("selected laps receive coaching interval names", {
  selected <- coaching_lap_fixture(c(1.3, 1.2), names = c("Lap 8", "Lap 10")) |>
    prepare_coaching_effort_presentation()

  expect_equal(
    selected$coaching_effort_name,
    c("Interval 1 (Lap 8)", "Interval 2 (Lap 10)")
  )
})

run_test("laps between selected efforts form duration-weighted recoveries", {
  laps <- coaching_lap_fixture(
    c(1.3, 0.6, 0.5, 1.25),
    duration = c(240, 300, 600, 240),
    names = c("Lap 8", "Lap 9", "Lap 10", "Lap 11")
  ) |>
    mutate(average_power_watts = c(340, 100, 130, 335))
  selected <- laps[c(1, 4), ] |>
    prepare_coaching_effort_presentation()
  recoveries <- summarise_recovery_intervals(laps, selected)

  expect_equal(recoveries$recovery_name, "R1")
  expect_equal(recoveries$moving_time_seconds, 900)
  expect_equal(recoveries$average_power_watts, 120)
  expect_equal(recoveries$source_laps, "Lap 9, Lap 10")
})

run_test("optional report notes accept pipes or newlines", {
  expect_equal(
    split_report_notes("First note|Second note\nThird note"),
    c("First note", "Second note", "Third note")
  )
  expect_equal(split_report_notes(""), character())
})

run_test("ride report power zones degrade gracefully without FTP", {
  report_streams <- tibble(watts = rep(200, 120))
  expect_equal(nrow(build_power_zones(report_streams)), 0L)
})

run_test("ride report excludes discontinuous Gold effort windows", {
  efforts <- tibble(
    duration_seconds = c(60L, 1200L),
    start_time_seconds = c(100L, 1000L),
    end_time_seconds = c(159L, 2500L)
  )
  continuous <- filter_continuous_efforts(efforts)

  expect_equal(continuous$duration_seconds, 60L)
})

run_test("coaching effort telemetry is normalised to the lap", {
  streams <- tibble(
    sample_index = 1:181,
    time_seconds = 0:180,
    distance_metres = 0:180,
    altitude_metres = 100,
    watts = 200,
    heartrate_bpm = 140,
    cadence_rpm = 85
  )
  effort <- coaching_lap_fixture(1.3, duration = 61) |>
    mutate(
      start_sample_index = 61L,
      end_sample_index = 121L,
      start_time_seconds = 60,
      end_time_seconds = 121,
      start_distance_metres = 60,
      end_distance_metres = 120
    )
  model <- build_coaching_effort_model(effort, streams)

  expect_equal(range(model$streams$effort_time_minutes), c(0, 1))
  expect_equal(
    range(model$streams$effort_distance_miles),
    c(0, 60 * 0.000621371)
  )
})

run_test("coaching effort telemetry uses canonical time boundaries", {
  streams <- tibble(
    sample_index = 1:300,
    time_seconds = 0:299,
    distance_metres = 0:299,
    altitude_metres = 100 + (0:299) / 10,
    watts = c(rep(100, 100), rep(300, 60), rep(100, 140)),
    heartrate_bpm = 140,
    cadence_rpm = 85
  )
  effort <- coaching_lap_fixture(1.3, duration = 60) |>
    mutate(
      start_sample_index = 1L,
      end_sample_index = 60L,
      start_time_seconds = 100,
      end_time_seconds = 160
    )
  model <- build_coaching_effort_model(effort, streams)

  expect_equal(nrow(model$streams), 60L)
  expect_equal(mean(model$streams$watts), 300)
})

run_test("coaching effort elevation scale is local to the lap", {
  elevation <- tibble(
    effort_time_minutes = 0:4,
    altitude_metres = c(120, 125, 130, 140, 150)
  )
  plot <- plot_coaching_effort_metric(
    elevation,
    "altitude_metres",
    "Elevation",
    "Elevation (m)",
    report_colours$elevation,
    "#D7E3D2"
  )
  y_range <- ggplot2::ggplot_build(plot)$layout$panel_params[[1]]$y.range

  expect_true(y_range[[1]] > 100)
})

cat(sprintf("\n%d tests passed.\n", tests_run))
