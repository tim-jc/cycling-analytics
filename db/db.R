get_database_config <- function() {
  required_keys <- c(
    "MARIADB_HOST",
    "MARIADB_PORT",
    "MARIADB_NAME",
    "MARIADB_USER",
    "MARIADB_PASSWORD"
  )
  values <- Sys.getenv(required_keys, unset = "")
  missing_keys <- required_keys[!nzchar(values)]

  if (length(missing_keys) > 0) {
    stop(
      "Missing required database configuration: ",
      paste(missing_keys, collapse = ", "),
      call. = FALSE
    )
  }

  db_port <- suppressWarnings(as.integer(values[["MARIADB_PORT"]]))

  if (is.na(db_port) || db_port < 1L || db_port > 65535L) {
    stop(
      "MARIADB_PORT must be an integer between 1 and 65535.",
      call. = FALSE
    )
  }

  list(
    host = values[["MARIADB_HOST"]],
    port = db_port,
    dbname = values[["MARIADB_NAME"]],
    user = values[["MARIADB_USER"]],
    password = values[["MARIADB_PASSWORD"]]
  )
}

connect_db <- function(max_attempts = 5, wait_seconds = 30) {
  config <- get_database_config()

  cat(glue::glue(
    "DB connection target host={config$host}; port={config$port}; dbname={config$dbname}; user={config$user}\n"
  ))

  for (i in seq_len(max_attempts)) {
    attempt_started_at <- Sys.time()

    cat(glue::glue(
      "DB connection attempt {i}/{max_attempts}\n"
    ))

    con <- tryCatch(
      DBI::dbConnect(
        RMariaDB::MariaDB(),
        host = config$host,
        port = config$port,
        dbname = config$dbname,
        user = config$user,
        password = config$password
      ),

      error = function(e) {
        cat(glue::glue(
          "Connection failed after {round(as.numeric(difftime(Sys.time(), attempt_started_at, units = 'secs')), 1)}s:\n"
        ))
        cat(conditionMessage(e), "\n")

        NULL
      }
    )

    if (!is.null(con)) {
      cat("DB connection successful.\n")

      return(con)
    }

    if (i < max_attempts) {
      Sys.sleep(wait_seconds)
    }
  }

  stop(glue::glue(
    "Unable to connect to database after {max_attempts} attempt(s): host={config$host}; port={config$port}; dbname={config$dbname}; user={config$user}"
  ))
}
