library(DBI)
library(tidyverse)
library(leaflet)

source(here::here("db", "db.R"))
source(here::here("dashboard_functions.R"))

con <- connect_db()

ytd_power_efforts_sql <- dbGetQuery(
    conn = con,
    "SELECT
        abe.activity_id,
        a.start_date_local, 
        a.sport_type, 
        abe.duration_seconds, 
        abe.metric_name, 
        abe.peak_value, 
        abe.start_sample_index, 
        abe.end_sample_index
    FROM cycling_platform_gold.activity_best_efforts abe 
    INNER JOIN cycling_platform_silver.activities a 
    ON abe.activity_id  = a.activity_id 
    WHERE metric_name = 'watts'
    AND YEAR(a.start_date_local) = YEAR(NOW())"
)

ytd_best_efforts <- ytd_power_efforts_sql |>
    group_by(metric_name, duration_seconds) |>
    slice_max(peak_value)

activity_ids <- str_flatten_comma(ytd_best_efforts$activity_id)

sql <- str_glue(
    "SELECT *
     FROM cycling_platform_silver.activity_streams
     WHERE activity_id IN ({activity_ids})"
)

streams <- dbGetQuery(conn = con, sql)

ytd_best_efforts_streams <- ytd_best_efforts |>
    inner_join(streams, by = "activity_id", relationship = "many-to-many") |>
    filter(sample_index >= start_sample_index, sample_index <= end_sample_index)


effort_stream <- ytd_best_efforts_streams |>
    filter(activity_id == 18436525360, duration_seconds == 1200) |>
    arrange(sample_index) |>
    mutate(
        distance_from_start_metres = distance_metres - min(distance_metres),
        gradient_block = floor(distance_from_start_metres / 1000)
    ) |>
    group_by(gradient_block) |>
    mutate(
        block_start_mi = first(effort_distance_mi),
        block_end_mi = last(effort_distance_mi),
        block_distance_metres = last(distance_metres) - first(distance_metres),
        altitude_start_metres = first(altitude_metres),
        altitude_end_metres = last(altitude_metres),
        gradient_percent = (altitude_end_metres - altitude_start_metres) / 1000
    )

draw_map(effort_stream)

# elevation plot
effort_stream |>
    ggplot(aes(x = distance_metres, y = altitude_metres)) +
    geom_line()

# power plot
effort_stream |>
    ggplot(aes(x = distance_metres, y = watts)) +
    geom_line()
