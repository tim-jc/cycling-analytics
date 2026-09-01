log_message <- function(msg) {
  timestamp <- format(
    Sys.time(),
    "%Y-%m-%d %H:%M:%S"
  )

  log_line <- glue::glue("[{timestamp}] {msg}")

  message(log_line)

  if (identical(Sys.getenv("DASHBOARD_LOG_REDIRECTED", ""), "TRUE")) {
    flush.console()
    return(invisible(TRUE))
  }

  log_file <- Sys.getenv("DASHBOARD_LOG", "")

  if (nzchar(log_file)) {
    tryCatch(
      suppressWarnings(
        cat(log_line, "\n", file = log_file, append = TRUE)
      ),
      error = function(e) {
        message(glue::glue(
          "[{timestamp}] Log file append skipped: {conditionMessage(e)}"
        ))
      }
    )
  }

  flush.console()
}
