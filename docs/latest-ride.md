# Latest Ride dashboard page

Latest Ride is the dashboard landing page. It gives a compact view of the most
recent significant cycling activity while keeping data selection and trusted
calculations outside the presentation markup.

## Selection rule

The page currently selects the newest significant cycling activity using two
presentation-specific rules:

- outdoor `Ride`: canonical distance of at least 20 miles;
- `VirtualRide` or trainer-flagged `Ride`: canonical moving time of at least
  20 minutes.

Both thresholds are inclusive and are held in
`LATEST_SIGNIFICANT_RIDE_MIN_DISTANCE_MI` and
`LATEST_SIGNIFICANT_INDOOR_MIN_MOVING_SECONDS` in
`latest_ride_functions.R`. `VirtualRide` is sufficient to classify an activity
as indoor because the platform's trainer flag is not necessarily set for
virtual activities.

This is a temporary dashboard heuristic, not a canonical platform
classification. A future cycling-platform activity-classification product can
replace it without changing the page layout.

If no activity qualifies, the page shows an explicit empty state and does not
fall back to an insignificant or non-cycling activity.

This analytical selector is deliberately distinct from the production success
notification. The notification is a freshness heartbeat and reports the
chronologically latest `Ride` or `VirtualRide` without either significance
threshold. Virtual/trainer activities receive a `(virtual)` qualifier there so
their distance is not presented as an outdoor ride.

## Data flow

1. Query `cycling_platform_silver.activities` at activity grain and select one
   ride using the page-specific significance policy.
2. Query `cycling_platform_silver.activity_streams` only for that activity.
3. Query ride-only power efforts from
   `cycling_platform_gold.activity_best_efforts` only for that activity.
4. Prepare labels, traces, map, table, and factual observations locally as
   presentation logic.

The primary analytical views are the route, a ride-only power curve sourced
from all available Gold best-effort durations, and a heart-rate zone
distribution. Comparative highlights rank canonical activity metrics and Gold
power efforts within the activity's calendar year.

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

Heart-rate zones are not yet a trusted platform product. They are therefore
disabled unless `CYCLING_ANALYTICS_HR_MAX_BPM` is explicitly configured. When
enabled, the dashboard uses isolated presentation-only zones at <60%, 60–70%,
70–80%, 80–90%, and >=90% of that value. This should move to cycling-platform
if zones become reusable by coaching, MCP, or other consumers.

Top-N rankings are likewise isolated presentation queries over canonical
Silver activity fields and Gold effort values. A future platform ranking
product should replace them if multiple consumers need the same comparisons.

The page deliberately omits coaching prescriptions, nutrition, estimated NP,
IF, TSS, and any PDF-report behaviour.

## Tests

Run `Rscript tests/run_tests.R`. The suite covers both outdoor and indoor
selection thresholds, cycling-only eligibility, newest qualifying selection,
notification independence, empty-state wording, and component-level handling
of missing streams.
