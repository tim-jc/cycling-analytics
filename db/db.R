library(DBI)
library(RMariaDB)

connect_db <- function(max_attempts = 5, wait_seconds = 30) {
  for (i in seq_len(max_attempts)) {
    cat(glue::glue(
      "DB connection attempt {i}/{max_attempts}\n"
    ))

    con <- tryCatch(
      dbConnect(
        RMariaDB::MariaDB(),
        host = Sys.getenv("MARIADB_HOST"),
        port = as.integer(Sys.getenv("MARIADB_PORT")),
        dbname = Sys.getenv("MARIADB_NAME"),
        user = Sys.getenv("MARIADB_USER"),
        password = Sys.getenv("MARIADB_PASSWORD")
      ),

      error = function(e) {
        cat("Connection failed:\n")
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

  stop("Unable to connect to database.")
}
