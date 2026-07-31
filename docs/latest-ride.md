# Latest Ride dashboard page

Latest Ride is the dashboard landing page. It gives a compact view of the most
recent significant cycling activity while keeping data selection and trusted
calculations outside the presentation markup.

## Selection rule

The page currently selects the newest `Ride` or `VirtualRide` whose canonical
activity distance is at least 20 miles. The threshold is inclusive and is held
in `LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI` in `latest_ride_functions.R`.

This is a temporary dashboard heuristic, not a canonical platform
classification. A future cycling-platform activity-classification product can
replace it without changing the page layout.

If no activity qualifies, the page shows an explicit empty state and does not
fall back to a shorter or non-cycling activity.

## Data flow

1. Query `cycling_platform_silver.activities` at activity grain and select one
   qualifying ride.
2. Query `cycling_platform_silver.activity_streams` only for that activity.
3. Query ride-only power efforts from
   `cycling_platform_gold.activity_best_efforts` only for that activity.
4. Prepare labels, traces, map, table, and factual observations locally as
   presentation logic.

The existing dashboard pages retain their current queries. Latest Ride adds no
Raw-layer dependency and performs no local reconstruction of canonical facts.

## Graceful fallbacks

- Missing elevation, power, heart-rate, or GPS streams affect only their own
  component.
- Indoor rides show a route-not-applicable message.
- Missing Gold efforts show an unavailable message rather than estimated
  efforts.
- No lap table is synthesized because the platform does not yet publish a
  curated lap product.
- `gear_id` is not presented as a bike name. Bike identity is deferred until a
  trusted equipment product is available.

The page deliberately omits coaching prescriptions, nutrition, estimated NP,
IF, TSS, and any PDF-report behaviour.

## Tests

Run `Rscript tests/run_tests.R`. The suite covers the selection threshold,
cycling-only eligibility, newest qualifying selection, empty-state wording,
and component-level handling of missing streams.
