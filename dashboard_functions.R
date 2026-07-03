# Define values -----------------------------------------------------------

# Peaks units / conversions
peaks_units <- tribble(
  ~metric           , ~display_name , ~multiplier , ~units  ,
  "cadence"         , "cadence"     , 1           , "rpm"   ,
  "watts"           , "power"       , 1           , "w"     ,
  "heartrate"       , "heart rate"  , 1           , "bpm"   ,
  "velocity_smooth" , "speed"       , 2.23694     , "mph"   ,
  "distance"        , "distance"    , 0.000621371 , "miles"
)

# Functions

# Get streams
get_streams <- function() {
  dbGetQuery(
    con,
    "SELECT
    a.activity_id,
    a.start_date_local,
    a.distance_metres, 
    a.moving_time_seconds, 
    a.energy_kilojoules,
    s.latitude,
    s.longitude
   FROM
    cycling_platform_silver.activities a
   INNER JOIN cycling_platform_silver.activity_streams s
    ON a.activity_id = s.activity_id
   WHERE
    a.sport_type IN ('Ride','VirtualRide')
    AND YEAR(a.start_date_local) >= (YEAR(NOW()) - 1)"
  )
}

# tbr streams
get_tbr_streams <- function() {
  dbGetQuery(
    con,
    "SELECT
      a.activity_id
     FROM
      cycling_platform_silver.activities a
     INNER JOIN cycling_platform_silver.activity_streams s
      ON a.activity_id = s.activity_id
     WHERE
      a.activity_name like '%tbr%'"
  )
}


# Assemble YTD stats
build_ytd_stats <- function(activity_streams) {
  activities <- activity_streams |>
    select(
      activity_id,
      start_date_local,
      distance_metres,
      moving_time_seconds,
      energy_kilojoules,
    ) |>
    distinct() |>
    mutate(
      yr = year(start_date_local),
      yr_day = yday(start_date_local),
      distance_mi = distance_metres * 0.000621371,
      is_ton = distance_mi >= 100,
      moving_time_hr = moving_time_seconds / 3600
    ) |>
    group_by(yr) |>
    arrange(start_date_local) |>
    mutate(
      ytd_distance_mi = cumsum(distance_mi),
      ytd_tons = cumsum(is_ton),
      ytd_time_hr = cumsum(moving_time_hr),
      ytd_energy_kcal = cumsum(replace_na(energy_kilojoules, 0)),
      ytd_longest_ride = max(
        distance_mi[yr_day <= yday(Sys.Date())],
        na.rm = T
      ),
      yr_longest_ride = max(distance_mi, na.rm = T)
    ) |>
    select(
      activity_id,
      distance_mi,
      start_date_local,
      is_ton,
      matches("^yr|^ytd")
    ) |>
    mutate(start_date_local = as.Date(start_date_local)) |>
    group_by(start_date_local, yr, yr_day) |>
    summarise(
      ytd_distance_mi = max(ytd_distance_mi),
      ytd_predicted_distance_mi = (ytd_distance_mi / yday(Sys.Date())) * 365,
      ytd_tons = max(ytd_tons),
      is_ton_day = any(is_ton),
      ytd_time_hr = max(ytd_time_hr),
      ytd_energy_kcal = max(ytd_energy_kcal),
      ytd_longest_ride = max(ytd_longest_ride, na.rm = T),
      yr_longest_ride = max(yr_longest_ride, na.rm = T),
      is_activity_day = TRUE,
      activity_id = activity_id[distance_mi == max(distance_mi)],
      .groups = "drop"
    ) |>
    group_by(yr) |>
    mutate(
      yr_distance_mi = max(ytd_distance_mi),
      yr_tons = max(ytd_tons),
      yr_time_hr = max(ytd_time_hr),
      yr_energy_kcal = max(ytd_energy_kcal)
    ) |>
    right_join(tibble(
      start_date_local = seq.Date(
        floor_date(floor_date(Sys.Date(), "month") - years(1), "year"),
        ceiling_date(Sys.Date(), "year") - days(1),
        "days"
      )
    )) |>
    mutate(
      yr = year(start_date_local),
      yr_day = yday(start_date_local),
      is_activity_day = if_else(is.na(is_activity_day), F, is_activity_day),
      is_ton_day = if_else(is.na(is_ton_day), F, is_ton_day)
    ) |>
    arrange(yr, yr_day) |>
    filter(!(yr == year(Sys.Date()) & yr_day > yday(Sys.Date()))) |>
    fill(-activity_id, .direction = "down") |>
    mutate(
      across(where(is.numeric), ~ replace_na(.x, 0)),
      across(where(is.logical), ~ replace_na(.x, FALSE))
    ) |> # in case no riding on first day of year.
    mutate(
      ytd_val = yr_day == yday(Sys.Date()),
      yr_lbl = if_else(yr == year(Sys.Date()), "ytd", "pytd")
    ) |>
    ungroup()
}


get_ytd_values <- function(metric_to_display, ytd_stats) {
  test <- ytd_stats |>
    filter(ytd_val) |>
    select(yr_lbl, matches("^ytd"), -ytd_val) |>
    pivot_longer(-yr_lbl, names_to = "metric") |>
    filter(str_detect(metric, metric_to_display)) |>
    mutate(
      value = round(value, 1),
      yr_lbl = if_else(
        str_detect(metric, "^yr_"),
        str_replace(yr_lbl, "td", "r"),
        yr_lbl
      )
    ) |>
    select(-metric) |>
    deframe()
}
