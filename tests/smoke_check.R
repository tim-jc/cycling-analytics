#!/usr/bin/env Rscript

fail <- function(...) {
  stop("Image smoke check failed: ", ..., call. = FALSE)
}

assert_true <- function(value, message) {
  if (!isTRUE(value)) {
    fail(message)
  }
}

project_root <- normalizePath(getwd(), winslash = "/", mustWork = TRUE)

assert_true(
  file.exists(file.path(project_root, "renv.lock")),
  paste0("project root is missing renv.lock: ", project_root)
)

required_files <- c(
  ".Rprofile",
  "render_dashboard.R",
  "dashboards/index.Rmd",
  "db/db.R",
  "runtime_helpers.R",
  "dashboard_functions.R",
  "latest_ride_functions.R",
  "renv/activate.R",
  "renv/settings.json",
  "scripts/docker-entrypoint.sh"
)

for (relative_path in required_files) {
  path <- file.path(project_root, relative_path)
  assert_true(
    file.exists(path),
    paste0("required application file is missing: ", relative_path)
  )
  assert_true(
    file.access(path, mode = 4L) == 0L,
    paste0("required application file is not readable: ", relative_path)
  )
}

assert_true(
  dir.exists(Sys.getenv("CYCLING_ANALYTICS_OUTPUT_DIR", unset = "")),
  "configured dashboard output directory does not exist"
)

library_root <- Sys.getenv("RENV_PATHS_LIBRARY", unset = "")
assert_true(
  nzchar(library_root),
  "RENV_PATHS_LIBRARY is not configured"
)
library_root <- normalizePath(library_root, winslash = "/", mustWork = TRUE)
active_libraries <- normalizePath(
  .libPaths(),
  winslash = "/",
  mustWork = TRUE
)
library_prefix <- paste0(library_root, "/")
uses_project_library <- any(
  active_libraries == library_root |
    startsWith(active_libraries, library_prefix)
)
assert_true(
  uses_project_library,
  paste0(
    "active R libraries do not include the explicit restored library under ",
    library_root,
    "; active libraries: ",
    paste(active_libraries, collapse = ", ")
  )
)

required_packages <- c(
  "DBI",
  "RMariaDB",
  "flexdashboard",
  "glue",
  "htmlwidgets",
  "knitr",
  "leaflet",
  "lubridate",
  "plotly",
  "renv",
  "rmarkdown",
  "tibble",
  "tidygeocoder",
  "tidyverse"
)
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
assert_true(
  length(missing_packages) == 0L,
  paste0(
    "restored runtime library is missing package(s): ",
    paste(missing_packages, collapse = ", ")
  )
)

assert_true(
  rmarkdown::pandoc_available(),
  "Pandoc is not installed or is not discoverable by rmarkdown"
)

dashboard_front_matter <- rmarkdown::yaml_front_matter(
  file.path(project_root, "dashboards", "index.Rmd")
)
dashboard_format <- dashboard_front_matter$output[[
  "flexdashboard::flex_dashboard"
]]
assert_true(
  identical(dashboard_format$self_contained, FALSE),
  "dashboard output is not explicitly configured as non-self-contained"
)

production_r_files <- c(
  "render_dashboard.R",
  "db/db.R",
  "runtime_helpers.R",
  "dashboard_functions.R",
  "latest_ride_functions.R"
)
for (relative_path in production_r_files) {
  tryCatch(
    parse(file = file.path(project_root, relative_path)),
    error = function(error) {
      fail(
        "production R source does not parse: ",
        relative_path,
        "; ",
        conditionMessage(error)
      )
    }
  )
}

dashboard_code <- tempfile(fileext = ".R")
on.exit(unlink(dashboard_code), add = TRUE)
tryCatch(
  {
    knitr::purl(
      file.path(project_root, "dashboards", "index.Rmd"),
      output = dashboard_code,
      quiet = TRUE
    )
    invisible(parse(file = dashboard_code))
  },
  error = function(error) {
    fail("dashboard R chunks do not parse: ", conditionMessage(error))
  }
)

entrypoint_environment <- new.env(parent = globalenv())
tryCatch(
  sys.source(
    file.path(project_root, "render_dashboard.R"),
    envir = entrypoint_environment
  ),
  error = function(error) {
    fail("render entry point cannot be sourced safely: ", conditionMessage(error))
  }
)
assert_true(
  is.function(entrypoint_environment$main),
  "render_dashboard.R did not define main()"
)

cat(
  "Image smoke check passed: source, renv library, runtime packages, ",
  "Pandoc, and production render code are structurally available.\n",
  sep = ""
)
