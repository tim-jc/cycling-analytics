# Cycling Analytics Roadmap

**Last reviewed:** 2026-11-26

**Operational state:** The batch dashboard has a documented production
operating model. The currently published production source SHA has not been
verified. Activity Inspector is intentionally a local-only application.

**Current delivery workstream:** Slice 2J production readiness

**Workstream lifecycle state:** Accepted; deployment pending

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
  publication. The SHA currently deployed and published has not been verified,
  so no equivalence between production and `447f559` is claimed. Repository
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
| Slice 2J dark cartography | MapTiler Streets v4 Dark across all four dark dashboard maps | Accepted | Owner validated all four maps in Safari and accepted the [production runbook](runtime-contract.md#dark-dashboard-basemaps) |
| Production revision reconciliation | Record the exact accepted SHA deployed and published by infrastructure | Ready | Deployment, refresh and publication evidence naming the Analytics SHA |

## Active work

**Current bounded item:** Deploy and verify the accepted Slice 2J revision after separate authorisation.

**Position:** The owner validated all four dark dashboard maps in Safari and
approved MapTiler Streets v4 Dark for production. Acceptance covers the shared
Leaflet helper, permanent `CYCLING_ANALYTICS_MAPTILER_KEY` setting, CARTO Dark
Matter when the key is absent or blank, and unchanged CARTO Positron in Activity
Inspector. The production configuration, deployment and rollback procedures
are accepted. All 157 regression tests, the repository smoke check and
`git diff --check` passed.

**Outstanding production evidence:** Record the deployed revision, successful
publication and live tile verification on both production hostnames.

## Dependencies

- `cycling-platform` owns the trusted Silver and Gold data consumed by the
  dashboard and Activity Inspector.
- `cycling-infrastructure` owns production image deployment, scheduled render,
  static artefact validation and Cloudflare Pages publication.

## Risks and blockers

- **Unknown published revision:** repository history cannot establish which
  Analytics SHA currently serves production. Resolve this from infrastructure
  deployment and publication evidence rather than inference.

## Deferred work

- Review non-terracotta route overlay contrast on MapTiler Streets Dark,
  particularly historical routes and TBR.
- Investigate the recurring nested macOS renv library directory.
- Investigate the PCRE match-limit warning after successful dashboard renders.

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

**Owner: authorise deployment separately, then follow the production runbook
and verify live tiles on both hostnames.**

## Revision history

| Date | Change | Reason / evidence |
| --- | --- | --- |
| 2026-11-26 | Slice 2J formally accepted | Owner validated all four maps in Safari and accepted production readiness. Deployment and live tile verification remain outstanding. |
| 2026-11-17 | Recorded Slice 2H acceptance and opened Slice 2I visual refinements | Owner accepted Slice 2H; Slice 2I remains awaiting visual acceptance |
| 2026-11-14 | Initial durable roadmap and accepted-feature reconciliation | Owner confirmed Activity Inspector acceptance and TBR acceptance dated 9 November 2026; current Git and operational evidence reconciled without making a deployment claim |
