# Ride Summary report

The Ride Summary is a compact Quarto PDF for post-ride coaching discussion. It
accepts one activity ID and produces a static report without publishing or
modifying platform data.

## Command

```sh
Rscript scripts/render_ride_summary.R \
  --activity-id 19457478741 \
  --ftp-watts 250 \
  --session-objective "4 x 4 min VO2 intervals at 330-350 W" \
  --rider-notes "Cadence felt better|Headwind on the final interval" \
  --coach-observations "Pacing improved after interval one|Final effort remained strong"
```

Output defaults to `report-output/pdf/ride-summary-<activity-id>.pdf`. Use
`--output-dir <path>` to choose another destination. Only `--activity-id` is
required; FTP-dependent metrics degrade gracefully.

The session objective remains optional until there is an agreed place to
persist it. Supplying `--session-objective` is strongly encouraged because it
provides the context for interpreting every effort. Rider notes and coach
observations are also optional; separate multiple entries with `|` or newline
characters. The report does not generate observations automatically.

## Architecture

```text
activity ID
  -> read-only report data adapters
  -> pure report/presentation model
  -> reusable tables and plots
  -> Quarto/Typst PDF
```

The data, model and presentation components are separate so a future MCP
adapter can reuse the report model without parsing a rendered PDF.

Trusted inputs are `silver.activities`, `silver.activity_streams`,
`silver.activity_laps`, and `gold.activity_best_efforts`.

## Selected Coaching Efforts

The complete canonical lap table is always included. A separate editorial
pipeline then decides whether any laps warrant detailed coaching telemetry:

1. Exclude short laps, heavily paused laps, explicitly named
   warm-up/recovery/cool-down laps, and laps without enough telemetry. The
   normal minimum is three minutes; a strong power lap may qualify from two
   minutes.
2. Identify a genuine signal: power meaningfully above the ride average, or a
   climb with at least 75 m gain and 300 m/h VAM.
3. Score the signal using relative power, climbing magnitude and sustained
   duration. Require a score of at least 1.5.
4. Take distinct category winners for average power, sustained power, elevation
   gain and VAM, then fill by score, normally selecting at most five laps.
5. When at least three strong laps have power within 10% of their median and
   are separated by recovery laps, treat them as one coherent work set. Keep
   the complete set together, subject to a hard ceiling of ten effort pages.

Selected laps receive presentation names such as `Interval 1 (Lap 8)`. A
single-page comparison table precedes the telemetry pages. Canonical laps
between consecutive selected efforts are summarised as recovery intervals;
their average power is weighted by moving duration.

Lap telemetry consumes the canonical Silver `start_time_seconds` and
`end_time_seconds` boundaries and applies the documented half-open interval:
`time_seconds >= start_time_seconds` and `time_seconds < end_time_seconds`.
Strava's source lap indexes are not used to join laps to Silver stream rows.

This deliberately permits zero selected efforts. Long, evenly paced endurance
laps remain visible in the lap table without automatically receiving telemetry
pages. Selection is presentation logic; it does not redefine the canonical
laps or claim that unselected laps are unimportant.

## Temporary report-only logic

The following calculations are isolated in `ride_report_model.R` and visibly
labelled as estimates:

- FTP-based power-zone allocation
- lap VAM used for coaching presentation and selection
- relative-power and climb-based lap significance scoring
- rejection of Gold effort windows containing elapsed-time discontinuities

Effort rejection is a presentation safeguard, not a replacement best-effort
calculation. If Gold's leading window is discontinuous, that duration remains
absent until the platform supplies the next valid continuous window.

NP, VI, IF and TSS are omitted until canonical products exist. The lap table
and coaching-effort cards show NP as unavailable rather than estimating it.

## Missing platform products

Future versions would benefit from:

- activity and lap NP/IF/TSS plus FTP history
- canonical power-zone time
- detected climbs and structured intervals
- reusable lap/effort significance or workout-intent products if other
  consumers eventually need consistent coaching selections
- HR-power decoupling
- weather associated with an activity
- equipment display identity from bike-library through an agreed interface
