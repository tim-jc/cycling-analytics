FROM rocker/r-ver:4.4.3

LABEL org.opencontainers.image.title="cycling-analytics"
LABEL org.opencontainers.image.description="Cycling analytics dashboard"
LABEL org.opencontainers.image.vendor="Tim Cross"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/London \
    LANG=en_GB.UTF-8 \
    LC_ALL=en_GB.UTF-8 \
    HOME=/tmp \
    TMPDIR=/tmp \
    RENV_PATHS_LIBRARY=/opt/cycling-analytics-library \
    RENV_CONFIG_CACHE_ENABLED=FALSE

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libfontconfig1-dev \
        libfribidi-dev \
        libgdal-dev \
        libharfbuzz-dev \
        libpng-dev \
        libssl-dev \
        libxml2-dev \
        locales \
        pandoc \
    && sed -i '/en_GB.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/cycling-analytics

# Restore dependencies before copying the application.
COPY renv.lock ./
COPY .Rprofile ./
COPY renv/ ./renv/

RUN Rscript --vanilla -e '\
    install.packages("renv", repos = "https://cloud.r-project.org"); \
    lock <- renv::lockfile_read("renv.lock"); \
    project_library <- renv::paths$library(); \
    dir.create(project_library, recursive = TRUE, showWarnings = FALSE); \
    renv::install(paste0("renv@", lock$Packages$renv$Version), library = project_library); \
    renv::restore(library = project_library, prompt = FALSE); \
    description <- read.dcf(file.path(project_library, "renv", "DESCRIPTION")); \
    stopifnot(identical(unname(description[1, "Version"]), lock$Packages$renv$Version))' \
    && test -z "$(find /opt/cycling-analytics-library -type l -print -quit)" \
    && chmod -R a+rX /opt/cycling-analytics-library

ENV RENV_CONFIG_SANDBOX_ENABLED=FALSE \
    R_LIBS_USER=/opt/cycling-analytics-library/linux-ubuntu-noble/R-4.4/aarch64-unknown-linux-gnu \
    CYCLING_ANALYTICS_OUTPUT_DIR=/app/output \
    CYCLING_ANALYTICS_RUN_MODE=render

COPY . .

RUN mkdir -p output

# TODO: Replace with a proper smoke test once one exists.
# RUN Rscript tests/smoke_check.R

CMD ["Rscript", "render_dashboard.R"]