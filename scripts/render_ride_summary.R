#!/usr/bin/env Rscript

parse_report_args <- function(args) {
  values <- list(
    activity_id = NULL,
    ftp_watts = NA_real_,
    session_objective = "",
    output_dir = "output/pdf"
  )
  index <- 1L
  while (index <= length(args)) {
    argument <- args[[index]]
    if (!argument %in% c(
      "--activity-id", "--ftp-watts", "--session-objective", "--output-dir"
    )) {
      stop("Unknown argument: ", argument, call. = FALSE)
    }
    if (index == length(args)) {
      stop("Missing value after ", argument, call. = FALSE)
    }
    value <- args[[index + 1L]]
    if (argument == "--activity-id") values$activity_id <- value
    if (argument == "--ftp-watts") {
      values$ftp_watts <- suppressWarnings(as.numeric(value))
    }
    if (argument == "--session-objective") {
      values$session_objective <- value
    }
    if (argument == "--output-dir") values$output_dir <- value
    index <- index + 2L
  }
  if (is.null(values$activity_id) ||
    !grepl("^[0-9]+$", values$activity_id)) {
    stop("--activity-id must be supplied as a numeric activity ID.", call. = FALSE)
  }
  if (!is.na(values$ftp_watts) && values$ftp_watts <= 0) {
    stop("--ftp-watts must be positive when supplied.", call. = FALSE)
  }
  values
}

script_argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (length(script_argument) != 1L) {
  stop("Unable to resolve the report renderer path.", call. = FALSE)
}
script_path <- normalizePath(sub("^--file=", "", script_argument))
project_root <- normalizePath(file.path(dirname(script_path), ".."))
args <- parse_report_args(commandArgs(trailingOnly = TRUE))

output_dir <- if (grepl("^/", args$output_dir)) {
  args$output_dir
} else {
  file.path(project_root, args$output_dir)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_dir <- normalizePath(output_dir, mustWork = TRUE)

quarto <- Sys.which("quarto")
if (!nzchar(quarto)) {
  stop("Quarto is required but was not found on PATH.", call. = FALSE)
}

report_source <- file.path(
  project_root, "reports", "ride-summary", "ride-summary.qmd"
)
output_name <- paste0("ride-summary-", args$activity_id, ".pdf")
quarto_args <- c(
  "render", report_source,
  "--to", "typst",
  "--output", output_name,
  "-P", paste0("activity_id:", args$activity_id),
  "-P", paste0("project_root:", project_root)
)
if (is.finite(args$ftp_watts)) {
  quarto_args <- c(
    quarto_args, "-P", paste0("ftp_watts:", args$ftp_watts)
  )
}

old_session_objective <- Sys.getenv(
  "RIDE_REPORT_SESSION_OBJECTIVE",
  unset = NA_character_
)
on.exit({
  if (is.na(old_session_objective)) {
    Sys.unsetenv("RIDE_REPORT_SESSION_OBJECTIVE")
  } else {
    Sys.setenv(RIDE_REPORT_SESSION_OBJECTIVE = old_session_objective)
  }
}, add = TRUE)
Sys.setenv(RIDE_REPORT_SESSION_OBJECTIVE = args$session_objective)

status <- system2(quarto, quarto_args)
if (!identical(status, 0L)) {
  stop("Ride Summary render failed with exit status ", status, call. = FALSE)
}

rendered_candidates <- c(
  file.path(project_root, output_name),
  file.path(dirname(report_source), output_name)
)
rendered_pdf <- rendered_candidates[file.exists(rendered_candidates)][1]
if (is.na(rendered_pdf)) {
  stop("Quarto completed but the rendered PDF could not be located.", call. = FALSE)
}

final_pdf <- file.path(output_dir, output_name)
if (!file.copy(rendered_pdf, final_pdf, overwrite = TRUE)) {
  stop("Unable to copy the rendered PDF to ", final_pdf, call. = FALSE)
}
unlink(rendered_pdf)
cat(final_pdf, "\n")
