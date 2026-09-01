# Cycling Analytics Architecture Assessment

Date: 26 July 2026

> **Historical assessment.** This document records the repository and operating
> model as reviewed on 26 July 2026. Its Mac cron, generated `docs/index.html`,
> Git publication and GitHub Pages references describe the former architecture
> and are intentionally retained as historical evidence. They are not current
> operating instructions. The accepted production contract is documented in
> [`runtime-contract.md`](runtime-contract.md): analytics now produces a
> validated complete site under `output/`, while infrastructure on
> `cycling-prod` owns scheduling and Cloudflare Pages publication.

## 1. Executive summary

`cycling-analytics` is fundamentally sound and already respects the most
important ecosystem boundary:

- It performs no database writes.
- It reads curated Silver tables and a Gold analytical product.
- It does not ingest sources or process Raw data.
- Its primary output is a presentation artefact.
- Its operational refresh is observable and reliably propagates most failures.

It is a batch static-dashboard generator, not a service:

```text
MariaDB -> R/flexdashboard render -> docs/index.html -> GitHub Pages
                                      |
                                      +-> notification
```

The repository is replaceable without losing raw cycling history. However, a
few definitions currently live only here: period-best selection, "TBR"
membership by activity-name convention, "ton" counting, weekly/YTD
interpretations, and YTD geographic extrema/place names. Most are acceptable
presentation logic; period-best semantics and potentially reusable geospatial
interpretation merit upstream consideration.

The most important pre-deployment issue is concrete correctness, not
architectural aesthetics: activity totals originate from an inner join to
stream samples. An otherwise valid activity without streams is excluded from
YTD totals, weekly volume, goals and ride summaries. Silver already provides an
activity-grain table, so this should be corrected before Pi deployment.

The second major decision is operational: there are two implementations of
publish/notify--one in R and another in the shell wrapper. The Docker deployment
should establish one production entry point and an explicit output/publication
contract.

Overall assessment:

- No rewrite is justified.
- R Markdown/flexdashboard should remain.
- `renv`, staged logging and the read-only database model should remain.
- A small data-access correction, an explicit container runtime contract, and a
  few reliability decisions are the only conservative `MUST`s.
- Modularising the 1,440-line helper file and promoting reusable calculations
  upstream can be evolutionary work.

No repository files were changed during the assessment itself.

## 2. Current architecture

```text
macOS cron
  -> scripts/run_dashboard_refresh.sh
     -> temporary runtime copy
        -> render_dashboard.R
           -> dashboards/index.Rmd
              -> MariaDB
                 -> silver.activities
                 -> silver.activity_streams
                 -> gold.activity_best_efforts
              -> reverse-geocoding service
              -> docs/index.html
     -> commit and push main
        -> GitHub Pages
     -> ntfy notification

Rendered dashboard in the browser
  -> Carto/OpenStreetMap map tiles
  -> Strava and Google Maps links
```

There are two execution paths:

1. Scheduled wrapper path: shell owns isolation, publication and notification;
   R is told to skip its own publish/notify stages.
2. Direct `Rscript render_dashboard.R`: R renders directly into the repository
   and owns Git publication and notification.

That duplication is currently functional but should not become the Docker
architecture.

The dashboard is R Markdown/flexdashboard, not Quarto. It uses
`rmarkdown::render()` and a flexdashboard YAML output declaration. Quarto is not
currently a runtime dependency.

## 3. Repository map and responsibilities

| Path | Current responsibility | Assessment |
|---|---|---|
| `README.md` | Setup, rendering, cron and troubleshooting | Useful but incomplete for container/runtime contracts |
| `.Rprofile` | Automatic `renv` activation | Appropriate development bootstrap |
| `renv.lock` | R 4.4.3 and package dependency lock | Strong reproducibility foundation |
| `render_dashboard.R` | R orchestration, logging, rendering, optional publish/notify | Clear entry point, but carries operations as well as rendering |
| `scripts/run_dashboard_refresh.sh` | Scheduled execution, isolation, locking, publishing, notification | Hardened and effective; partly macOS-specific |
| `dashboards/index.Rmd` | Dashboard structure, data-loading sequence and page composition | Understandable, but data acquisition occurs inside presentation execution |
| `dashboard_functions.R` | SQL, transformations, metric preparation, components, plots and maps | Main maintainability concentration |
| `db/db.R` | MariaDB connection and retry | Small and appropriately isolated |
| `runtime_helpers.R` | Logging, cron install/check, schedule display, R-side Git and ntfy | Mixed macOS/runtime/application concerns |
| `exploration/` | Dated analytical experiments | Correct general location; one current untracked empty experiment |
| `ride_finder.R` | Legacy exploratory calls using undefined functions | Orphaned exploratory artefact |
| `docs/index.html` | Generated, tracked GitHub Pages output | Deliberate published artefact, currently about 25 MB |
| `_site.yml` | Legacy site output configuration | Apparently unused by the explicit render path |
| `analytics/`, `mcp/`, `reports/` | Empty, untracked directories | No current architectural role |
| `.Renviron` | Local secrets/runtime configuration | Correctly ignored |
| `dashboard_refresh.log` | Runtime log | Correctly ignored; needs a Linux sink/retention decision |

## 4. Automated execution flow

### Scheduled path

1. Cron invokes `scripts/run_dashboard_refresh.sh`.
2. The wrapper resolves its repository root from its own location.
3. It sets a cron-safe `PATH`, `LANG` and `LC_ALL`.
4. It resolves `Rscript`, preferring known macOS/Homebrew locations and falling
   back to `command -v`.
5. It creates `/tmp/cycling-analytics-dashboard.lock`.
6. It copies the project with `rsync` into
   `/tmp/cycling-analytics-runtime-$$`, excluding Git, logs and local `renv`
   runtime directories.
7. It exports the temporary directory as `RENV_PROJECT` and
   `CYCLING_ANALYTICS_PROJECT_DIR`.
8. It sets `DASHBOARD_SKIP_PUBLISH=TRUE` and
   `DASHBOARD_SKIP_NOTIFY=TRUE`.
9. It feeds the copied `render_dashboard.R` through `Rscript -`.
10. R resolves the temporary project, activates `renv`, checks required
    packages and sources database/runtime/dashboard helpers.
11. `rmarkdown::render()` executes `dashboards/index.Rmd`.
12. The dashboard connects to MariaDB, loads data, prepares presentation
    objects and renders HTML.
13. R writes notification context, closes the database connection and exits.
14. The wrapper copies the rendered HTML back to `docs/index.html`.
15. It stages that file, commits if changed, and pushes `origin main`.
16. It sends an ntfy message with publication context.
17. The trap removes the temporary directory and lock.

Observed scheduled runs show the full sequence completing in approximately
75-82 seconds, with most time in data loading/rendering.

### Failure propagation

Strong points:

- R stage failures are logged and rethrown.
- Top-level R errors exit with status 1.
- The wrapper records the R exit code.
- Copy, Git push and notification failures return non-zero.
- Database cleanup uses `on.exit`.
- Logs contain stage, elapsed time, working directory and environment context.

Exceptions:

- An existing lock exits successfully with status 0.
- A stale lock can therefore suppress every future run indefinitely.
- R-side `httr::POST()` does not call `stop_for_status()`, so HTTP errors may not
  fail direct R execution.
- Notification failure occurs after publication and makes the wrapper fail, but
  there is no separate failure-notification path.

## 5. External interfaces and dependencies

### Data interfaces

All production SQL is read-only.

| Object | Use |
|---|---|
| `cycling_platform_silver.activities` | Activity metadata and totals |
| `cycling_platform_silver.activity_streams` | GPS, altitude, power and sample telemetry |
| `cycling_platform_gold.activity_best_efforts` | Canonically calculated per-activity best efforts and record eligibility |

No Raw objects are queried. No `INSERT`, `UPDATE`, `DELETE`, DDL or database
write APIs are used.

### Runtime configuration

Local configuration keys are:

- `MARIADB_HOST`
- `MARIADB_PORT`
- `MARIADB_NAME`
- `MARIADB_USER`
- `MARIADB_PASSWORD`
- `DASHBOARD_REFRESH_SCHEDULE`
- `RSTUDIO_PANDOC`
- `NTFY_TOPIC`

`ANNUAL_DISTANCE_GOAL_MI` is also supported but is currently absent from the
local file.

### External network dependencies

- MariaDB
- ntfy
- GitHub remote/GitHub Pages
- reverse-geocoding through `tidygeocoder`
- Carto/OpenStreetMap map tiles in the rendered browser
- Strava activity links
- Google Maps links
- CRAN during dependency restoration, not normal rendering

### Executables

- R/Rscript
- Pandoc
- Bash
- `rsync`
- Git
- `curl`
- `awk`
- cron only for macOS scheduling

## 6. Classification of significant analytical logic

| Logic | Classification | Current location | Assessment |
|---|---|---|---|
| Per-activity best-effort rolling windows and eligibility | Canonical | `cycling-platform` Gold | Correctly consumed rather than recalculated |
| Selecting best eligible effort by duration and period | Canonical/reusable boundary | `get_ytd_best_power_efforts()`, `draw_critical_metric_curve()` | Same answer should generally be shared by MCP/coaching; consider Gold achievements or a stable product |
| YTD totals and previous-year comparisons | Presentation-specific aggregation | `build_ytd_stats()` | Reasonable locally while used only by this dashboard |
| Weekly distance/time/work/elevation and four-week average | Presentation logic | `draw_weekly_training_volume()` | Display window, week grain and comparison are dashboard choices |
| Annual goal progress and pace | Presentation/personal preference | Goal functions and environment configuration | Correctly local |
| "Ton" as ride at least 100 miles and count | Ambiguous | `build_ytd_stats()` | Acceptable personal metric; promote only if another consumer needs the same definition |
| Indoor/outdoor display split | Presentation logic based on canonical sport type | `get_ride_mix_valuebox()` | Correctly local |
| Ten-sample power smoothing | Presentation logic | `rolling_mean_trailing()` | Chart smoothing, not a platform fact |
| Kilometre gradient blocks and colour bands | Presentation logic | Elevation-gradient functions | Clearly visual transformation |
| Geographic N/S/E/W extrema | Reusable analytical logic candidate | `get_position_extremities()` | Could serve other geospatial consumers, but current YTD/card usage is presentation-specific |
| Reverse-geocoded place selection | Reusable geospatial derivation candidate | `get_position_extremities()` | Better upstream/cached if reused; currently an external render dependency |
| TBR membership from `activity_name LIKE '%tbr%'` | Ambiguous business/presentation rule | `get_tbr_streams()` | Needs an explicit statement of whether TBR is merely a personal view or a durable route/category |
| Distance/time unit conversion and labels | Presentation logic | Several functions | Reasonably local, although Silver already exposes miles |

## 7. What is structurally sound

These choices should be preserved:

- **Read-only consumer posture.** The repository does not mutate platform data.
- **No Raw-layer dependency.** It consumes curated Silver and Gold.
- **Canonical best-effort calculation remains upstream.** Analytics respects
  `is_record_eligible`.
- **Explicit Gold provenance.** The dashboard uses Gold window indexes to
  retrieve the corresponding telemetry.
- **Portable project-root resolution.** Rendering does not depend on an old
  machine path.
- **Pinned R environment.** `renv.lock` pins R 4.4.3 and package versions.
- **Observable refresh execution.** Existing staged logs answer whether a run
  started, where it failed and how long it took.
- **Correct cleanup structure.** Connections and temporary directories are
  cleaned in normal failure paths.
- **Presentation technology isolation from the platform.** Flexdashboard
  choices do not affect upstream data architecture.
- **Exploration is allowed to remain lightweight.** The dated script convention
  is already useful.
- **Tracked publication output is intentional.** Given GitHub Pages,
  `docs/index.html` has a clear current purpose.

## 8. Significant findings

### F01 - Activity totals depend on stream availability

- **Class:** A - Analytics architecture
- **Priority:** MUST
- **Current behaviour:** `get_streams()` inner-joins activities to stream
  samples. `build_activity_summary()` and `build_ytd_stats()` then deduplicate
  activity columns from this stream-shaped result.
- **Evidence:** `dashboard_functions.R:16`, `dashboard_functions.R:68`,
  `dashboards/index.Rmd:29`.
- **Why it matters:** Any valid activity without stream rows disappears from
  distance, time, elevation, work, goals and weekly trends. Silver already
  exposes canonical activity-grain data independently.
- **Target responsibility:** Analytics should query `silver.activities` for
  activity summaries and `silver.activity_streams` only for maps/telemetry.
- **Recommended change:** Split activity and stream acquisition while
  preserving current visuals.
- **Dependencies:** Add regression fixtures for an activity with no streams.
- **Timing:** Now, before Pi deployment.

### F02 - Stream acquisition is broader and heavier than necessary

- **Class:** A
- **Priority:** SHOULD
- **Current behaviour:** Nearly two years of activity metadata are duplicated
  onto every stream sample and loaded before every page renders.
- **Evidence:** `dashboard_functions.R:19`.
- **Why it matters:** Load/render stages take roughly 30-76 seconds and will
  scale with stream history. Summary pages do not need sample-grain data.
- **Target responsibility:** Analytics data-access functions with explicit
  grains.
- **Recommended change:** Query activity summaries separately; retrieve
  GPS/telemetry only for pages requiring it, with explicit selected columns and
  date scope.
- **Dependencies:** F01 and basic result-equivalence tests.
- **Timing:** Before deployment if convenient; otherwise soon after.

### F03 - Period-best selection remains locally defined

- **Class:** B - Platform boundary
- **Priority:** SHOULD
- **Current behaviour:** Analytics selects the best YTD effort and
  all-time/current/previous-year curves from per-activity Gold efforts. It also
  contains a local virtual-speed exclusion.
- **Evidence:** `dashboard_functions.R:437`, `dashboard_functions.R:1331`.
- **Why it matters:** "What was the rider's best valid 20-minute power?" should
  have the same answer in analytics, MCP and coaching. The platform already has
  `gold.activity_achievements`, including calendar-year and all-time power
  achievements.
- **Target responsibility:** `cycling-platform`.
- **Recommended change:** First evaluate whether `gold.activity_achievements`
  satisfies the dashboard. Add another stable Gold view only if the existing
  product cannot express current-best curves.
- **Dependencies:** Platform contract decision; avoid breaking the current
  dashboard meanwhile.
- **Timing:** Deferred coordinated migration; not a Docker blocker.

### F04 - Reusable training-load products are correctly absent locally

- **Class:** C - Missing platform product
- **Priority:** DO NOT CHANGE locally
- **Current behaviour:** Analytics presents volume--distance, time, work and
  elevation--but does not invent FTP, IF or TSS.
- **Evidence:** `dashboard_functions.R:1026`; the platform design explicitly
  reserves `activity_training_load` and `ftp_history`.
- **Why it matters:** Future health/coaching views will need reusable
  intensity/load definitions.
- **Target responsibility:** `cycling-platform`.
- **Recommended change:** Continue using presentation-level volume here.
  Implement training load upstream only when that work is deliberately started.
- **Dependencies:** FTP history and power metrics.
- **Timing:** Defer.

### F05 - Geospatial extrema and geocoding expose a future product gap

- **Class:** C
- **Priority:** COULD
- **Current behaviour:** Every render derives YTD N/S/E/W extrema from full
  streams and reverse-geocodes them over the network.
- **Evidence:** `dashboard_functions.R:159`.
- **Why it matters:** The location interpretation is non-deterministic, adds an
  external dependency to rendering, and could be reused by MCP or exploration
  tooling.
- **Target responsibility:** Analytics may own YTD/card selection; platform
  should own stable reusable route/location derivations if a second consumer
  appears.
- **Recommended change:** Isolate the geocoding dependency now; consider a
  platform route/geospatial product only when reuse is concrete.
- **Dependencies:** A defined geospatial product and privacy policy.
- **Timing:** Defer.

### F06 - TBR and "ton" conventions are undocumented boundary decisions

- **Class:** B
- **Priority:** COULD
- **Current behaviour:** TBR rides are identified by activity names containing
  `tbr`; a "ton" is locally defined as distance at least 100 miles.
- **Evidence:** `dashboard_functions.R:43`, `dashboard_functions.R:84`.
- **Why it matters:** If these are merely dashboard filters, local ownership is
  correct. If they are durable route/category or achievement facts, deleting
  analytics loses their definitions.
- **Target responsibility:** Document as presentation conventions; promote
  upstream only if other consumers need them.
- **Recommended change:** Record intent before moving anything.
- **Dependencies:** User decision about TBR semantics.
- **Timing:** Defer.

### F07 - One large file mixes most application responsibilities

- **Class:** E - Code quality
- **Priority:** SHOULD
- **Current behaviour:** `dashboard_functions.R` contains SQL, model
  preparation, goal logic, reusable calculations, HTML components, Plotly,
  ggplot, JavaScript and Leaflet code.
- **Evidence:** `dashboard_functions.R`.
- **Why it matters:** The file is understandable in sections but difficult to
  test or grow safely.
- **Target responsibility:** Local analytics modules.
- **Recommended change:** After tests, split by responsibility rather than by
  arbitrary file size.
- **Dependencies:** F12.
- **Timing:** Before or shortly after deployment; not a blocker.

### F08 - Production orchestration is implemented twice

- **Class:** D - Operations
- **Priority:** MUST
- **Current behaviour:** Direct R execution performs Git publication and ntfy
  through R helpers. Scheduled execution disables those implementations and
  repeats them in Bash.
- **Evidence:** `render_dashboard.R:377`,
  `scripts/run_dashboard_refresh.sh:153`.
- **Why it matters:** Docker needs one authoritative execution contract. The two
  paths differ in HTTP failure handling, logging and artefact flow.
- **Target responsibility:** Analytics owns rendering; deployment orchestration
  owns scheduling/credentials. Notification may remain an explicit post-render
  step.
- **Recommended change:** Choose one production path before writing Docker
  configuration. Preserve the other only as a clearly documented development
  convenience.
- **Dependencies:** F09.
- **Timing:** Now, before Docker design.

### F09 - Publication assumes a writable Git checkout and credentials

- **Class:** D
- **Priority:** MUST
- **Current behaviour:** The scheduled process overwrites tracked
  `docs/index.html`, commits to `main` and pushes `origin main`.
- **Evidence:** `scripts/run_dashboard_refresh.sh:109`,
  `scripts/run_dashboard_refresh.sh:153`.
- **Why it matters:** A normal container image is immutable and may not contain
  `.git` or credentials. Rendering from a dirty development checkout can also
  publish output that does not correspond to a committed source revision.
- **Target responsibility:** Publication mechanism belongs to the agreed
  deployment architecture.
- **Recommended change:** Decide whether Pi production will retain GitHub Pages
  and push through a mounted writable checkout/credential, or emit HTML to a
  volume and let infrastructure publish/serve it separately. Record the source
  commit/image version in logs.
- **Dependencies:** Infrastructure and secret-delivery decision.
- **Timing:** Now.

### F10 - Lock handling can suppress future runs indefinitely

- **Class:** D
- **Priority:** MUST if the wrapper is retained
- **Current behaviour:** Any existing lock directory is treated as an
  overlapping run and exits 0. A SIGKILL or host failure can leave a stale
  directory.
- **Evidence:** `scripts/run_dashboard_refresh.sh:305`.
- **Why it matters:** Future scheduled runs can silently skip forever while
  appearing successful to cron.
- **Target responsibility:** Runtime orchestration.
- **Recommended change:** On Linux use a process-aware lock such as `flock`, or
  validate owner PID/age. Distinguish "already running" from stale/error states.
- **Dependencies:** Final scheduler/container model.
- **Timing:** Before deploying this wrapper.

### F11 - Schedule parsing supports less than its documented contract

- **Class:** D
- **Priority:** SHOULD
- **Current behaviour:** Configuration is documented as standard five-field
  cron, but `get_next_dashboard_run()` only understands one minute field and
  comma-separated hours; it ignores day/month/weekday.
- **Evidence:** `runtime_helpers.R:149`, `README.md:34`.
- **Why it matters:** The dashboard and notification can display a wrong
  next-run time.
- **Target responsibility:** Runtime/presentation integration.
- **Recommended change:** Either constrain/document the supported schedule form
  or use the infrastructure scheduler as the source of truth.
- **Dependencies:** Docker scheduling decision.
- **Timing:** Before changing the schedule shape.

### F12 - No automated tests exist

- **Class:** E
- **Priority:** SHOULD
- **Current behaviour:** There is no test directory despite several pure
  transformation functions and important edge cases.
- **Evidence:** Repository inventory; no test/spec files.
- **Why it matters:** F01 and later module splits touch established working
  behaviour. Edge cases include no streams, no outdoor rides, year boundaries,
  missing power and empty weeks.
- **Target responsibility:** `cycling-analytics`.
- **Recommended change:** Add a small test suite around presentation models and
  a render smoke test before structural refactoring.
- **Dependencies:** None.
- **Timing:** Before significant restructuring.

### F13 - A dormant energy metric has the wrong unit name

- **Class:** E
- **Priority:** SHOULD
- **Current behaviour:** `energy_kilojoules` is cumulatively summed into
  `ytd_energy_kcal` without conversion.
- **Evidence:** `dashboard_functions.R:94`.
- **Why it matters:** It is currently dormant, but future use would expose an
  incorrect unit.
- **Target responsibility:** Local presentation model.
- **Recommended change:** Rename to kJ or perform an explicit conversion before
  using it.
- **Dependencies:** Tests.
- **Timing:** Before exposing the metric.

### F14 - Database configuration validation is weak

- **Class:** D
- **Priority:** SHOULD
- **Current behaviour:** Missing values become empty strings or `NA` port values
  and then enter a five-attempt retry loop. The final failed attempt is followed
  by another sleep.
- **Evidence:** `db/db.R:1`.
- **Why it matters:** Container configuration errors can take minutes to report
  and produce less direct diagnostics.
- **Target responsibility:** Application startup validation; secret provisioning
  remains infrastructure.
- **Recommended change:** Validate required keys immediately, retain retry only
  for genuine network readiness, and avoid sleeping after the final attempt.
- **Dependencies:** Container environment contract.
- **Timing:** Before or during Docker implementation.

### F15 - Timezone and locale need an explicit Linux contract

- **Class:** D
- **Priority:** MUST
- **Current behaviour:** R uses local `Sys.Date()`/`Sys.time()` while SQL uses
  MariaDB `NOW()`. The wrapper defaults to `en_GB.UTF-8`, which may not exist in
  a minimal Linux image.
- **Evidence:** `dashboard_functions.R:37`,
  `scripts/run_dashboard_refresh.sh:14`.
- **Why it matters:** Calendar-year/YTD results can diverge near midnight/year
  boundaries; an unavailable locale causes warnings or startup problems.
- **Target responsibility:** Deployment configuration with consistent
  application/database timezone.
- **Recommended change:** Set an explicit production timezone, likely
  `Europe/London`, and install/use a Linux-supported UTF-8 locale such as
  `C.UTF-8` where appropriate.
- **Dependencies:** Pi database/container configuration.
- **Timing:** Before deployment.

### F16 - Logging is strong; only its sink/lifecycle needs adaptation

- **Class:** D
- **Priority:** DO NOT CHANGE core design
- **Current behaviour:** Staged R and shell logs record start, success/failure,
  duration, cwd, environment and command status.
- **Evidence:** `render_dashboard.R:75`,
  `scripts/run_dashboard_refresh.sh:137`.
- **Why it matters:** This already provides proportionate observability.
- **Target responsibility:** Analytics keeps stage semantics; infrastructure
  chooses stdout/file retention.
- **Recommended change:** In Docker, emit to stdout/stderr or mount/rotate the
  existing log. Do not replace this with a new observability stack.
- **Dependencies:** Container logging choice.
- **Timing:** During deployment.

### F17 - Runtime/presentation staging is visible but data loading remains inside rendering

- **Class:** A
- **Priority:** SHOULD
- **Current behaviour:** Connect and Load Data stages are defined in the R
  Markdown setup chunk, so the renderer executes acquisition, preparation and
  presentation as one document evaluation.
- **Evidence:** `dashboards/index.Rmd:12`.
- **Why it matters:** Stages are diagnosable, but data preparation cannot easily
  be tested or reused independently of document rendering.
- **Target responsibility:** R orchestration should produce a
  presentation-data environment; R Markdown should mainly compose views.
- **Recommended change:** Incrementally move acquisition/preparation behind
  explicit functions without changing flexdashboard.
- **Dependencies:** F01, F12.
- **Timing:** Structural improvement, not a deployment blocker.

### F18 - Legacy and unused material obscures repository intent

- **Class:** E
- **Priority:** COULD
- **Current behaviour:** `ride_finder.R` calls missing functions; `_site.yml` is
  not used by the render entry point; `draw_rolling_activity_curve()` is unused;
  `mapdata` and likely `leaflet.extras` are loaded but unused; empty top-level
  directories imply architecture that does not exist.
- **Evidence:** `ride_finder.R:1`, `dashboard_functions.R:979`.
- **Why it matters:** New contributors cannot distinguish active architecture
  from historical experiments.
- **Target responsibility:** Local repository hygiene.
- **Recommended change:** After agreeing architecture, classify each as retained
  exploration, active source or removable legacy.
- **Dependencies:** User confirmation.
- **Timing:** Defer.

## 9. Exploratory-analysis assessment

The existing dated filename is a good lightweight convention:

```text
exploration/YYYY-MM-DD_topic.R
```

Plain R scripts are entirely appropriate. Notebooks should remain optional.

Recommended convention:

- `exploration/` may contain incomplete, lightly documented and non-production
  code.
- A short header should state the question, input tables and whether the result
  is provisional.
- Throwaway local work may remain ignored/untracked.
- Useful investigations may remain in Git without production tests.
- Code used by the dashboard should be promoted into a tested analytics
  presentation module.
- Definitions needed by MCP/coaching/another app should be proposed to
  `cycling-platform`.
- Experimental SQL may read Silver/Gold but should not become an undocumented
  production contract.

The best-efforts exploration demonstrates the intended lifecycle: investigate
locally, then consume the canonical Gold best-effort product in production.

## 10. Runtime state and generated artefacts

| Item | Classification | Lifecycle |
|---|---|---|
| `dashboard_functions.R`, `render_dashboard.R`, Rmd, shell scripts | Source code | Tracked |
| `.Rprofile`, `_site.yml`, `renv/settings.json` | Configuration | Tracked; `_site.yml` appears legacy |
| `.Renviron` | Runtime configuration/secrets | Ignored; never image-bake |
| `renv.lock`, `renv/activate.R` | Dependency specification/bootstrap | Tracked |
| `renv/library/` | Platform-specific dependency cache | Ignored; rebuild per environment |
| `docs/index.html` | Generated published output | Tracked for GitHub Pages |
| `dashboard_refresh.log` | Runtime log | Ignored; rotate or redirect in production |
| `/tmp/cycling-analytics-runtime-*` | Disposable render workspace | Removed by wrapper |
| `/tmp/cycling-analytics-dashboard.lock` | Runtime coordination state | Disposable but stale-lock risk |
| `.DS_Store` | Local filesystem noise | Correctly ignored |
| R Markdown intermediate files | Disposable build artefacts | Currently cleaned by render |
| Browser map tiles | External runtime content | Not stored locally |

`.gitignore` is broadly correct. No Quarto supporting directory currently exists
because the dashboard is a self-contained R Markdown HTML output.

## 11. Growth and container readiness

### Growth readiness

The repository can accommodate more dashboards and reports without changing the
platform. The limiting factor is the concentration of responsibilities in
`dashboard_functions.R`, not flexdashboard itself.

Health, equipment and geospatial presentation can fit naturally once their
reusable data products exist upstream:

- Health joins and reusable health summaries: platform Gold.
- Equipment identity and maintenance: bike-library, exposed through an agreed
  interface.
- Training load and FTP history: platform Gold.
- Maps, filters and visual storytelling: analytics.
- MCP remains a peer consumer, not an analytics client.

### Deployment model

From Docker's perspective the application is:

- A scheduled batch job.
- One primary render command.
- A set of R packages restored from `renv.lock`.
- A Pandoc-based static HTML renderer.
- A read-only MariaDB client.
- Optional Git and ntfy publication steps.

Required runtime inputs:

- Database host, port, name, read-only user and password.
- Timezone.
- Optional annual goal.
- Notification topic/URL if notifications remain enabled.
- Output/publication configuration.
- Scheduler configuration, preferably owned by `cycling-infrastructure`.

Required output/state:

- `docs/index.html` or another configured output path.
- Logs to stdout or a persistent/rotated file.
- No application database.
- No canonical persistent data.
- A Git checkout and credentials only if Git publication is deliberately
  retained.

Likely Linux system dependencies include:

- R 4.4.x and development toolchain during image build
- Pandoc
- MariaDB client development libraries for `RMariaDB`
- curl/SSL/XML libraries required by R packages
- geospatial/system libraries pulled by mapping dependencies
- Git, `rsync` and `curl` only if the current shell workflow remains

The exact ARM64 package build should be proven during the Docker exercise;
`renv.lock` is portable, while the current macOS `renv/library` is correctly
excluded.

## 12. Recommended target architecture

```text
cycling-platform trusted products
  -> analytics data access
     -> presentation models
        -> charts, maps and components
           -> R Markdown / future presentation shell
              -> static published output

cycling-infrastructure
  -> single refresh runner
     -> render
     -> configured publisher
     -> notification
```

Principles:

- One production refresh entry point.
- Activity and stream grains are explicitly separated.
- Dashboard documents compose prepared presentation objects.
- Gold establishes reusable truth.
- Analytics derives view-specific periods, labels and visual transformations.
- Publication is configurable and not assumed to require a mutable image.
- Staged logging is preserved.
- Flexdashboard remains replaceable without moving platform logic.

### Current vs proposed directory structure

No large reorganisation is necessary. A proportionate eventual structure would
be:

```text
Current                              Proposed evolution

dashboard_functions.R                R/data_access.R
                                     R/presentation_models.R
                                     R/components.R
                                     R/visualisations.R

db/db.R                              R/database.R

runtime_helpers.R                    R/runtime.R
                                     scripts/install_macos_cron.R
                                     # retained only while needed

dashboards/index.Rmd                 dashboards/index.Rmd
render_dashboard.R                   render_dashboard.R
scripts/run_dashboard_refresh.sh     scripts/run_dashboard_refresh.sh

exploration/                         exploration/
docs/                                docs/
                                     tests/testthat/
```

This is justified only after regression tests. It is not a request to create a
package or abstraction framework.

## 13. Prioritised pre-deployment change plan

### MUST

1. Correct activity-grain acquisition so activities without streams remain in
   totals.
2. Choose and document one production refresh entry point.
3. Decide the Docker output/publication contract and Git credential model.
4. Establish timezone, locale, database network and secret-delivery
   configuration.
5. Replace or harden the lock if the shell wrapper remains the production
   runner.
6. Define scheduling order relative to the platform pipeline so analytics reads
   published, validated data.

### SHOULD

1. Add focused tests before restructuring.
2. Separate stream-heavy queries from summary queries.
3. Validate startup configuration and improve retry behaviour.
4. Align period-best queries with Gold achievements or another explicit
   platform contract.
5. Split the monolithic helper file by responsibility.
6. Correct the dormant kJ/kcal naming issue.
7. Make the schedule-display contract match the scheduler.
8. Preserve staged logging while adapting its sink for Docker.

### COULD

1. Promote reusable geospatial derivations when a second consumer appears.
2. Document TBR and "ton" semantics.
3. Tidy legacy files, unused functions/dependencies and empty directories.
4. Add a lightweight exploration README/convention.
5. Improve render provenance by showing source commit/image version.

### DO NOT CHANGE

- Do not replace flexdashboard merely for architectural fashion.
- Do not duplicate training-load or FTP logic locally.
- Do not move every weekly/YTD aggregation upstream.
- Do not replace the existing staged logging model.
- Do not add an API/service layer without a concrete consumer.
- Do not make MCP consume `cycling-analytics`.
- Do not remove tracked HTML until the publication strategy changes.

## 14. Findings summary

| ID | Class | Finding | Priority | Target owner | Now/defer |
|---|---|---|---|---|---|
| F01 | A | Activity totals depend on stream existence | MUST | cycling-analytics | Now |
| F02 | A | Stream acquisition is overly broad/heavy | SHOULD | cycling-analytics | Now/soon |
| F03 | B | Period-best selection remains local | SHOULD | cycling-platform | Defer/co-ordinate |
| F04 | C | Training-load/FTP products are upstream gaps | DO NOT CHANGE locally | cycling-platform | Defer |
| F05 | C | Reusable geospatial/geocoding product gap | COULD | cycling-platform | Defer |
| F06 | B | TBR and "ton" semantics are undocumented | COULD | Joint decision | Defer |
| F07 | E | Main helper file mixes responsibilities | SHOULD | cycling-analytics | Soon |
| F08 | D | Publish/notify orchestration exists twice | MUST | analytics/infrastructure | Now |
| F09 | D | Publication assumes mutable Git checkout | MUST | cycling-infrastructure | Now |
| F10 | D | Stale lock can suppress all future runs | MUST if retained | runtime/infrastructure | Now |
| F11 | D | Cron parser is narrower than documented | SHOULD | cycling-analytics | Soon |
| F12 | E | No automated tests | SHOULD | cycling-analytics | Before refactor |
| F13 | E | kJ value is labelled kcal | SHOULD | cycling-analytics | Before use |
| F14 | D | Weak startup configuration validation | SHOULD | cycling-analytics | During Docker work |
| F15 | D | Timezone/locale contract is implicit | MUST | cycling-infrastructure | Now |
| F16 | D | Logging model is strong | DO NOT CHANGE | analytics/infrastructure | Preserve |
| F17 | A | Data loading remains embedded in rendering | SHOULD | cycling-analytics | Incremental |
| F18 | E | Legacy/unused material obscures intent | COULD | cycling-analytics | Defer |

The desired replaceability test is almost met: deleting this repository would
not lose cycling history or per-activity canonical best efforts. The remaining
weaknesses are a handful of locally held interpretations, not a shadow
ingestion or transformation platform. The target can be reached through small,
staged changes rather than a rewrite.
