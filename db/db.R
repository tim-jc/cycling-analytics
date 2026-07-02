library(DBI)
library(RMariaDB)
library(dotenv)

connect_db <- function() {
  load_dot_env()

  con <- dbConnect(
    RMariaDB::MariaDB(),
    host = Sys.getenv("DB_HOST"),
    port = as.integer(Sys.getenv("DB_PORT")),
    dbname = Sys.getenv("DB_NAME"),
    user = Sys.getenv("DB_USER"),
    password = Sys.getenv("DB_PASSWORD")
  )

  return(con)
}

with_db_connection <- function(code_block) {
  con <- NULL

  tryCatch(
    {
      con <- connect_db()

      return(code_block(con))
    },
    error = function(e) {
      cat("ERROR:\n")
      cat(e$message, "\n")

      return(NULL)
    },
    finally = {
      if (!is.null(con)) {
        dbDisconnect(con)
      }
    }
  )
}
