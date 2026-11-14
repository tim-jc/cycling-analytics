# Cycling Analytics Roadmap

**Last reviewed:** 2026-11-14

**Operational state:** The batch dashboard has a documented production
operating model. The currently published production source SHA has not been
verified. Activity Inspector is intentionally a local-only application.

**Current delivery workstream:** Navigation Instrument Slice 2H iOS
presentation corrections

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
- **Navigation Instrument:** the presentation baseline through Slice 2G is
  committed at `44b941b`. The desktop visual acceptance check for the Slice 2G
  dark maps remains outstanding; this qualification does not reopen previously
  accepted feature functionality.
- **Production publication:** cycling-infrastructure owns deployment and
  publication. The SHA currently deployed and published has not been verified,
  so no equivalence between production and `44b941b` is claimed. Repository
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
| Navigation Instrument through Slice 2G | Committed application shell, responsive presentation, charts and dark dashboard maps | Awaiting acceptance | Source committed through `44b941b`; desktop dark-map visual check remains |
| Slice 2H iOS corrections | Correct value-box icons, Plotly overlaps, narrow duration labels and Best Efforts clipping | Awaiting acceptance | Local implementation awaits owner visual review |
| Production revision reconciliation | Record the exact accepted SHA deployed and published by infrastructure | Ready | Deployment, refresh and publication evidence naming the Analytics SHA |

## Active work

**Current bounded item:** Owner visual acceptance of Slice 2H, including the
outstanding desktop check of the Slice 2G dark maps.

**Position:** Slice 2H is implemented as local, uncommitted changes. It must not
be described as accepted, committed or published until the corresponding owner
review and later delivery steps occur.

**Evidence needed for acceptance:** Owner observation of the affected dashboard
surfaces on iOS Safari and desktop, with either explicit acceptance or a bounded
defect list.

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
- **Uncommitted Slice 2H work:** the current four-file implementation is a
  coherent resumption point but is not durable delivery evidence until accepted
  and committed.

## Deferred work

- Retire Coastal Ride Explorer in a separate bounded cleanup task. Activity
  Inspector is accepted as its functional replacement for boundary discovery,
  but this repository does not claim that the legacy tool has already been
  removed.

## Next action

**Owner: complete the Slice 2H iOS/desktop visual review, including the remaining
Slice 2G dark-map check, and record acceptance or a bounded defect list.**

## Revision history

| Date | Change | Reason / evidence |
| --- | --- | --- |
| 2026-11-14 | Initial durable roadmap and accepted-feature reconciliation | Owner confirmed Activity Inspector acceptance and TBR acceptance dated 9 November 2026; current Git and operational evidence reconciled without making a deployment claim |
