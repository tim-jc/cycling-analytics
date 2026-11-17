# Cycling Analytics Roadmap

**Last reviewed:** 2026-11-17

**Operational state:** The batch dashboard has a documented production
operating model. The currently published production source SHA has not been
verified. Activity Inspector is intentionally a local-only application.

**Current delivery workstream:** Navigation Instrument Slice 2I visual
refinements

**Workstream lifecycle state:** Awaiting acceptance

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
| Slice 2I visual refinements | Recover summary plotting space, clarify the Best Efforts period and improve effort/historical map legibility | Awaiting acceptance | Local implementation awaits owner visual review |
| Production revision reconciliation | Record the exact accepted SHA deployed and published by infrastructure | Ready | Deployment, refresh and publication evidence naming the Analytics SHA |

## Active work

**Current bounded item:** Navigation Instrument Slice 2I visual refinements.

**Position:** Slice 2H is accepted and committed. Slice 2I is implemented
locally and must not be described as accepted, committed or published until the
corresponding owner review and later delivery steps occur.

**Evidence needed for acceptance:** Owner observation that summary charts use
their space efficiently, Best Efforts communicates its reporting year and short
effort and historical route maps provide adequate geographic distinction.

## Dependencies

- `cycling-platform` owns the trusted Silver and Gold data consumed by the
  dashboard and Activity Inspector.
- `cycling-infrastructure` owns production image deployment, scheduled render,
  static artefact validation and Cloudflare Pages publication.
- Owner visual judgement is required for the active presentation acceptance.

## Risks and blockers

- **Unknown published revision:** repository history cannot establish which
  Analytics SHA currently serves production. Resolve this from infrastructure
  deployment and publication evidence rather than inference.

## Deferred work

- Retire Coastal Ride Explorer in a separate bounded cleanup task. Activity
  Inspector is accepted as its functional replacement for boundary discovery,
  but this repository does not claim that the legacy tool has already been
  removed.

## Next action

**Owner: review the locally rendered Slice 2I summary charts, Best Efforts maps
and historical route map, then record acceptance or a bounded defect list.**

## Revision history

| Date | Change | Reason / evidence |
| --- | --- | --- |
| 2026-11-17 | Recorded Slice 2H acceptance and opened Slice 2I visual refinements | Owner accepted Slice 2H; Slice 2I remains awaiting visual acceptance |
| 2026-11-14 | Initial durable roadmap and accepted-feature reconciliation | Owner confirmed Activity Inspector acceptance and TBR acceptance dated 9 November 2026; current Git and operational evidence reconciled without making a deployment claim |
