# TBR Family Adventures dashboard

The TBR page is a family adventure journal for bicycle outings with a toddler
passenger. It deliberately avoids training, performance, target and streak
language.

## Membership

An activity belongs to the page when its canonical Silver `sport_type` is
`Ride` and its activity name contains `tbr`, case-insensitively. There is no
minimum distance or duration. Each matching activity is one adventure, even
when several occur on the same local calendar day.

The activity name is the authoritative personal presentation rule. `gear_id`
is retained in the activity data so bike consistency can be audited, but it is
not a membership condition: an outing on another or unknown bike remains an
adventure. This is not a canonical platform activity classification.

## Data responsibilities

`get_tbr_activities()` retrieves one activity-grain row per adventure from
`cycling_platform_silver.activities`. Counts, summaries, calendar cells and
milestones all use this complete history and do not depend on stream
availability.

`get_tbr_position_streams()` separately retrieves only latitude, longitude and
sample order for the selected activity IDs. Missing GPS therefore removes only
map geometry; it never removes an adventure from the journal or its totals.

Summary values mean:

- **Adventures:** qualifying activity count;
- **Miles together:** sum of canonical activity distance, treating missing
  measurements as unavailable contributions rather than missing adventures;
- **Time riding together:** sum of canonical moving time, not elapsed time;
- **First adventure:** earliest local activity date after deterministic ordering
  by local start datetime and activity ID.

## Adventure calendar

The calendar has one row per calendar year and January–December columns. Cell
intensity represents the number of adventures; hover text includes count and
mileage. Completed months without outings are explicit zeroes. Months after
the current local month are marked as future rather than zero-activity months.

## Adventure map

The map retains the CARTO Voyager basemap. Historical routes are light and the
most recent adventure with usable geometry is highlighted. If the newest
adventure has no usable GPS, the label says `Latest mapped adventure` and the
unmapped count remains visible rather than misrepresenting the older route as
the newest adventure.

The initial viewport fits that latest mapped adventure rather than the complete
history. Map controls provide `Latest`, automatically discovered `Area N`
views, a bounded number of recent `One-off N` views, and `All adventures`.
These controls only change the viewport: every route, popup and route style
remains loaded and unchanged.

### Geographic focus areas

Focus discovery uses the first valid coordinate of each mapped route as its
activity-level representative. TBR outings commonly begin at a local or
temporary riding base, and this choice prevents a long route's distant endpoint
from bridging otherwise separate areas. It is only a clustering representative;
it is not labelled or interpreted as a home address.

Representative positions are compared with Haversine distance. Deterministic
complete-link hierarchical clustering ensures that every pair of representatives
within one cluster is no more than the configured threshold apart, avoiding the
chaining behaviour of single-link clustering. Inputs are sorted by activity ID
before clustering, so database row order does not affect the result.

The explicit initial parameters in `tbr_functions.R` are:

- `TBR_FOCUS_DISTANCE_KM = 25`;
- `TBR_FOCUS_MIN_CLUSTER_SIZE = 2` adventures;
- no more than six area controls;
- no more than three recent isolated-adventure controls;
- 24-pixel viewport padding;
- maximum zoom 14 for Latest, 12 for areas and 10 for All adventures.

Clusters are labelled `Area 1`, `Area 2`, and so on in order of their earliest
adventure. No reverse geocoding or external location lookup is used. A single
isolated latest adventure remains available through `Latest`; up to three other
recent isolated adventures receive individual `One-off N` controls. Older
isolated adventures remain present and clickable in `All adventures`, avoiding
both dozens of buttons and one misleading combined outlier viewport.

Area bounds use the complete valid route geometry of every assigned activity.
Latest uses the complete latest mapped route, and All adventures uses all mapped
geometry. Valid points are not silently removed to improve framing. Padding and
maximum zoom safeguards prevent overly close views while allowing Leaflet to
preserve the container aspect ratio.

Popups contain the local date, activity name, canonical distance and a Strava
link. Names are HTML-escaped. Map preparation accepts paired, finite,
in-range coordinates, requires non-degenerate line geometry, preserves sample
order and splits lines at missing, invalid or absent sample rows. It does not
interpolate or apply jump, speed or distance thresholds.

## Milestones

Milestones are descriptive journal events, not targets or badges. Activities
are ordered by `start_datetime_local, activity_id`. The page includes reached
count milestones at 10, 25, 50 and 100 adventures; the first crossing of 100,
250, 500 and 1,000 cumulative miles; the first adventure; the longest
adventure; and the most active month.

Most-active-month ties are resolved by adventure count, cumulative distance,
then earliest month. Missing distance contributes zero to cumulative mileage
without removing the adventure. Unreached thresholds are omitted.

## Deferred capabilities

New-territory coverage, route novelty and home-relative distance require
deliberate geospatial definitions and, for home-relative measures, explicit
user-supplied reference data. They are not inferred or calculated by this
dashboard.
