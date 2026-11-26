# Cycling Analytics Roadmap

**Last reviewed:** 2026-11-26

**Operational state:** Slice 2K deployed and published on 26 November 2026,
as confirmed by the owner. Activity Inspector remains local-only.

**Current delivery workstream:** None; Slice 2K closed

**Workstream lifecycle state:** Slice 2K deployed and closed

## Mission

Cycling Analytics is the predominantly read-only presentation and exploration
layer for trusted cycling-platform data. It owns dashboards, reports and local
inspection experiences; production execution and publication are owned by
cycling-infrastructure.

## Current accepted state

- **Activity Inspector:** functional owner acceptance is confirmed from real
  coastal-boundary discovery. Its implementation is committed in `057098e` and
  it supersedes Ride Explorer for that purpose. It remains a standalone local
  Shiny application, so production deployment is not applicable to its current
  design. Coastal Ride Explorer has not been removed; its retirement is a
  separate cleanup task. Repository evidence: [Activity Inspector](activity-inspector.md).
- **TBR family adventures:** the owner explicitly accepted the functional TBR
  updates on 9 November 2026. The committed feature baseline includes the
  family-journal summaries, calendar, milestones and cumulative map with
  geographic focus controls. Repository evidence: [TBR family adventures](tbr-adventures.md).
- **Navigation Instrument:** the presentation baseline through Slice 2H is
  committed at `447f559`. The owner accepted Slice 2H on 17 November 2026.
- **Production publication:** cycling-infrastructure owns deployment and
  publication. The owner confirmed the Slice 2K production revision as
  `a61fb6b`. Repository
  evidence: [runtime contract](runtime-contract.md).

Owner acceptance above is owner-reported evidence now recorded durably in this
repository. Commit references and linked documentation are repository-recorded
implementation evidence; neither alone is treated as deployment evidence.

## Target state

Maintain a clear accepted dashboard and local-inspection baseline, with the
accepted source revision and the production-published revision recorded
separately. Complete current visual acceptance before starting another
presentation slice.

## Delivery phases and milestones

| Phase / milestone | Outcome | State | Acceptance evidence |
| --- | --- | --- | --- |
| Activity Inspector functional baseline | Local read-only boundary discovery using canonical Silver samples | Accepted | Owner-reported successful use on real coastal-boundary work; implementation and operating contract documented in [Activity Inspector](activity-inspector.md) |
| TBR family-adventure baseline | Accepted family journal, temporal summaries, milestones and cumulative map | Accepted | Explicit owner acceptance on 9 November 2026; implementation documented in [TBR family adventures](tbr-adventures.md) |
| Navigation Instrument through Slice 2H | Committed application shell, responsive presentation, charts, maps and iOS corrections | Accepted | Owner accepted Slice 2H on 17 November 2026; source committed at `447f559` |
| Slice 2I visual refinements | Recover summary plotting space, clarify the Best Efforts period and improve historical map legibility | Accepted | Baseline committed at `214b345` |
| Slice 2J dark cartography | MapTiler Streets v4 Dark across all four dark dashboard maps | Deployed and closed | Owner confirmed publication and all four maps on both production hostnames; see the [production acceptance record](runtime-contract.md#slice-2j-production-acceptance) |
| Slice 2K route legibility | Pale slate historical routes on Historical Activity and TBR | Deployed and closed | [Production acceptance record](runtime-contract.md#slice-2k-production-acceptance) |
| Production revision reconciliation | Record the exact accepted SHA deployed and published by infrastructure | Closed | Owner-confirmed revision and production checks recorded in the runtime contract |

## Active work

**Current bounded item:** None. The December usage review is an operational follow-up.

**Position:** The owner validated all four dark dashboard maps in Safari and
approved MapTiler Streets v4 Dark for production. Acceptance covers the shared
Leaflet helper, permanent `CYCLING_ANALYTICS_MAPTILER_KEY` setting, CARTO Dark
Matter when the key is absent or blank, and unchanged CARTO Positron in Activity
Inspector. The production configuration, deployment and rollback procedures
are accepted. All 157 regression tests, the repository smoke check and
`git diff --check` passed.

**Production evidence:** The owner confirmed production refresh, publication
and visual acceptance of `a61fb6b` at 12:16 UTC on 26 November 2026.

## Dependencies

- `cycling-platform` owns the trusted Silver and Gold data consumed by the
  dashboard and Activity Inspector.
- `cycling-infrastructure` owns production image deployment, scheduled render,
  static artefact validation and Cloudflare Pages publication.

## Risks and blockers

- **Shared MapTiler key:** quota exhaustion, abuse or key rotation can affect
  both Analytics and Explorer. See the [runtime contract](runtime-contract.md#shared-key-and-usage).

## Slice 2K — Dark Map Route Legibility

Owner-accepted on 26 November 2026. The owner independently reviewed complete
local dashboard renders with MapTiler Streets v4 Dark and CARTO Dark Matter;
all seven visual acceptance criteria passed. This closes the route overlay
contrast backlog item.

Historical Activity and TBR historical routes share pale slate
(`#B1C2CB`, 2.5 px, 0.62 opacity). TBR's latest mapped route remains
terracotta (`#D18B58`, 4.5 px, 1.0 opacity); Latest Ride and Best Efforts are
unchanged. Route geometry, layer ordering, viewport and controls were
preserved. All 157 regression tests and the local smoke check passed;
`renv.lock` is unchanged. Production delivery and visual acceptance are
confirmed in the [runtime contract](runtime-contract.md#slice-2k-production-acceptance).

## Deferred work

- Investigate the recurring nested macOS renv library directory.
- **PCRE match-limit warning — deferred unless it recurs (26 November 2026):**
  The confirmed source is rmarkdown 2.29's HTML image-processing postprocessor.
  A failed match can skip local image-path rewrites, but no dashboard
  functionality or publication defect was observed. The exact trigger remains
  unverified; no evidence establishes MapTiler as the cause. The bounded
  diagnostic render was inconclusive because database connectivity failed
  before final HTML processing. The owner accepted no remediation at present.
  If the warning recurs, record the render stage, versions, basemap mode and
  artefact size without recording HTML, URLs, credentials or activity data.
  Seek owner approval for further bounded diagnostics and confirm read-only
  database connectivity before attempting another diagnostic render.

- Retire Coastal Ride Explorer in a separate bounded cleanup task. Activity
  Inspector is accepted as its functional replacement for boundary discovery,
  but this repository does not claim that the legacy tool has already been
  removed.
- **Best Efforts — detailed dark cartography:** the existing CARTO Dark Matter
  basemap provides limited geographical context for short effort traces. Stadia
  Alidade Smooth Dark has been visually reviewed and is a credible alternative,
  but any new provider decision should follow the broader cartographic
  requirements and provider selection established through Explorer development.
  This is a deliberate deferral, not an unresolved acceptance defect.

## Next action

**5 January 2027 at 09:00 UK time:** Review combined Analytics and Explorer MapTiler usage
for December 2026, the first full production month.

## Revision history

| Date | Change | Reason / evidence |
| --- | --- | --- |
| 2026-11-26 | Slice 2K accepted and closed in production | Owner confirmed refresh, publication and visual acceptance of `a61fb6b`. |
| 2026-11-26 | Slice 2J accepted and closed in production | Owner confirmed deployment, publication and live tiles on both hostnames. |
| 2026-11-17 | Recorded Slice 2H acceptance and opened Slice 2I visual refinements | Owner accepted Slice 2H; Slice 2I remains awaiting visual acceptance |
| 2026-11-14 | Initial durable roadmap and accepted-feature reconciliation | Owner confirmed Activity Inspector acceptance and TBR acceptance dated 9 November 2026; current Git and operational evidence reconciled without making a deployment claim |
