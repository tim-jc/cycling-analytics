DASHBOARD_IDENTITY_NAME <- "past-the-grid-identity"
DASHBOARD_IDENTITY_VERSION <- "1.0.5"

dashboard_identity_dependency <- function(project_root) {
  dependency_dir <- file.path(project_root, "assets")
  dependency_path <- paste0(
    "index_files/",
    DASHBOARD_IDENTITY_NAME,
    "-",
    DASHBOARD_IDENTITY_VERSION
  )

  htmltools::htmlDependency(
    name = DASHBOARD_IDENTITY_NAME,
    version = DASHBOARD_IDENTITY_VERSION,
    src = c(file = dependency_dir),
    stylesheet = c("identity/tokens.css", "dashboard.css"),
    script = "dashboard-shell.js",
    attachment = c(
      symbol = "identity/symbol-dark.svg",
      favicon_svg = "identity/favicon.svg",
      favicon_png = "identity/favicon.png",
      provenance = "identity/PROVENANCE.md"
    ),
    head = paste0(
      '<link rel="icon" type="image/svg+xml" href="',
      dependency_path,
      '/identity/favicon.svg">',
      '<link rel="icon" type="image/png" sizes="64x64" href="',
      dependency_path,
      '/identity/favicon.png">'
    ),
    all_files = FALSE
  )
}

register_dashboard_identity <- function(project_root) {
  knitr::knit_meta_add(list(dashboard_identity_dependency(project_root)))
  invisible(TRUE)
}
