connect_db <- function(max_attempts = 5, wait_seconds = 30) {
  db_host <- Sys.getenv("MARIADB_HOST")
  db_port <- as.integer(Sys.getenv("MARIADB_PORT"))
  db_name <- Sys.getenv("MARIADB_NAME")
  db_user <- Sys.getenv("MARIADB_USER")

  cat(glue::glue(
    "DB connection target host={db_host}; port={db_port}; dbname={db_name}; user={db_user}\n"
  ))

  for (i in seq_len(max_attempts)) {
    attempt_started_at <- Sys.time()

    cat(glue::glue(
      "DB connection attempt {i}/{max_attempts}\n"
    ))

    con <- tryCatch(
      DBI::dbConnect(
        RMariaDB::MariaDB(),
        host = db_host,
        port = db_port,
        dbname = db_name,
        user = db_user,
        password = Sys.getenv("MARIADB_PASSWORD")
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

    Sys.sleep(wait_seconds)
  }

  stop(glue::glue(
    "Unable to connect to database after {max_attempts} attempt(s): host={db_host}; port={db_port}; dbname={db_name}; user={db_user}"
  ))
}
