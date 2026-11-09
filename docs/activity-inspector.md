# Activity Inspector

The Activity Inspector is a standalone, local Shiny application for read-only
exploration of one canonical Silver cycling activity. It is separate from the
static cycling dashboard and does not render, publish or modify dashboard
output.

## Launch

From the repository root:

```sh
Rscript -e "shiny::runApp('apps/activity-inspector', launch.browser = TRUE)"
```

The application uses the existing local environment contract:

- `MARIADB_HOST`
- `MARIADB_PORT`
- `MARIADB_NAME`
- `MARIADB_USER`
- `MARIADB_PASSWORD`
- `CARTO_BASEMAP_API_KEY`

Use a MariaDB account restricted to `SELECT` access. Local values may be kept in
the ignored `.Renviron` file. The CARTO key is used by the client-side Leaflet
basemap and must not be committed.

## Inspection workflow

1. Enter a numeric Strava activity ID and select **Load activity**.
2. Click the route or a timeline observation to inspect its canonical Silver
   sample index.
3. Assign the current sample as the start or end boundary.
4. Refine either boundary with the previous/next stored-sample controls or enter
   an exact existing index.
5. Fit the map to the highlighted inclusive range if required.
6. Copy the boundaries for manual use elsewhere.

The copied form is:

```text
ride_start_sample_index = 123
ride_end_sample_index = 456
```

Copying uses the browser clipboard only. The application does not persist the
selection or edit Coastal's authoritative boundary definitions.

## Data behaviour

Each explicit load opens a database connection, executes parameterised
activity-scoped `SELECT` queries, closes the connection and retains the returned
snapshot in that Shiny session. Map navigation and selection do not query the
database again.

The inspector preserves the one-based Silver `sample_index`, missing values and
sample gaps. Route geometry includes only finite in-range coordinate pairs and
is split at missing/invalid coordinates and non-consecutive stored indices. It
does not interpolate, repair or renumber samples. A range may include samples
without GPS; only its valid, contiguous mapped portions are highlighted.

`time_seconds` is displayed as elapsed stream time. It is not presented as a
stored wall-clock timestamp. Silver's positional alignment of unequal source
arrays remains subject to the cycling-platform contract review.

Map clicks select the nearest valid canonical coordinate. Where several samples
are spatially plausible, the application states that the result is ambiguous
and leaves exact refinement to the timeline or stored-sample controls.

The map retains full-resolution route geometry without permanent per-sample
markers. Selection overlays and markers update with `leafletProxy()`. The
timeline uses Plotly WebGL and carries canonical sample indices as interaction
data.

## Scope

The inspector is not a data editor, boundary store, integrity classifier or
Coastal-specific application. Advanced GPS diagnostics, lap overlays,
persistent annotations, public hosting and Docker deployment are deferred.

Coastal's `ride_explorer.R` remains in place until the inspector has passed the
separate practical retirement acceptance process against known and unfamiliar
coastal rides.
