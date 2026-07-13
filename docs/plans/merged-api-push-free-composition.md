# Push-free schema composition via merged APIs

**Status:** PLANNED (Phase 0 spike is the go/no-go gate)
**Date:** 2026-07-14
**Analysis:** [docs/analysis/merged-api-push-free-approach.md](../analysis/merged-api-push-free-approach.md)
**Succeeds:** [docs/plans/done/event-sourced-fragment-registries.md](done/event-sourced-fragment-registries.md)
(shipped + deploy-validated 2026-07-14 — the push path this plan migrates off; it stays
the working baseline until the cutover phase here completes).
**Related backlog:** `Backlog/harmonize-local-deploy-lifecycle.md` (scope-2 local
decoupling — Phase 6 here lands alongside it).

## Problem

The shipped push path works, but it *manages* a coordination problem rather than removing
it: N concurrent deploys still funnel into one whole-replace AppSync schema through a
single-writer automation (ApiFragmentRegistry aggregate + reactive SideEffect + deploy
caller/waiter). AppSync **Merged APIs** dissolve the problem instead: each plugin owns its
own **source API** (schema + resolvers, single writer by construction) and AWS composes the
merged endpoint. No shared artifact → no registry, no reactive push, no waiter, no
retirement gap (delete the source API and its fields vanish).

Full feasibility, constraints, and design sketches: analysis §§ 2–12. This plan sequences
the migration.

## Decisions carried in from the analysis

| Decision | Choice | Analysis ref |
|---|---|---|
| Relay `node` | prototype **field-resolver indirection (c)**; fall back to **drop global `node` (a)**; never **(b)** admin-owns-all-data-sources | § 12 |
| Fragment registry under merge | **retired on the API side — neither aggregate nor slice**; no thin DCB ledger unless a concrete discovery/audit need appears | § 9 |
| UiFragmentRegistry | **unchanged** — runtime-connect-driven, not a schema push | § 9 |
| Plugin aggregate | **unchanged** — lifecycle only | § 9 |
| Split mode | Domain + Platform **merged** APIs; `apiTarget` collapses to "which merged API ARN the association points at" | § 3, § 11 |
| Shared types | admin source API owns them `@canonical`; codegen emits reference-only/`@hidden` elsewhere | § 12 |
| Subscriptions | a subscription and every mutation its `@aws_subscribe` fans in from must live in the same source API | § 4 risk 4, § 12 |
| Merge mode | `AUTO_MERGE` + association-status poll to fail loudly on `MERGE_FAILED` | § 10 |
| Alpha data | **wipe alpha stacks over migration code** — no schema-state migration path is built | repo convention |

Provider separation holds throughout: merged-API/AppSync concepts live in
`reventless-aws` (and `rescript-pulumi-aws`); core keeps neutral SDL + neutral names.

## Phase 0 — AWS spike (go/no-go gate)

A throwaway Pulumi program (not framework code): one admin source API + two domain plugin
source APIs merged into one Domain merged API. Validates the four behaviors the AWS docs
leave least certain for this codebase:

1. **Shared-type merge** — Relay base types (`PageInfo`, `Node`, connection types) + the
   `CommandResult` union family emitted `@canonical` from the admin source, referenced/
   stubbed from the plugin sources; confirm union-of-identical-fields merges and a
   deliberately divergent field flips only that association to `MERGE_FAILED`.
2. **Relay `node` via field-resolver indirection (option c)** — thin admin `node` returning
   a typed stub, concrete fields resolved by the owning source API. **This is the gate:**
   if (c) proves too heavy, decide (a) — dropping global `node` — explicitly before
   proceeding; option (b) is rejected up front.
3. **Per-plugin Source-C subscription merge** — each plugin source carries its own
   subscriptions linked to its own mutations; confirm they merge and fire.
4. **Cognito + IAM dual-auth** — merged API with Cognito primary + IAM secondary; per-field
   `@aws_iam` on a source's `Platform_*`-shaped fields; confirm SigV4 and Cognito callers
   both work through the merged endpoint.

Also confirm operationally: auto-merge propagation latency, `GetSourceApiAssociation`
status/error detail on failure, and the 10-source-API default limit (file the
limit-increase request early if the spike passes).

**Exit criteria:** all four validated (with the `node` decision recorded in this plan), or
the plan moves to `docs/plans/Backlog/` with the blocking finding documented.

## Phase 1 — Pulumi bindings (`rescript-pulumi-aws`)

Net-new bindings (grep-confirmed absent; analysis § 11):

- Extend `GraphQLApi` with `apiType` (`GRAPHQL` | `MERGED`) + `mergedApiExecutionRole`.
- `aws.appsync.GraphQLSchema` — the declarative per-source-API schema resource (replaces
  imperative `StartSchemaCreation`; viable again because each source API is single-owner —
  analysis § 10).
- `aws.appsync.SourceApiAssociation` — `mergeType`, `mergedApiIdentifier`,
  `sourceApiIdentifier`. Consider the `aws-native` Cloud Control resource, consistent with
  the existing `aws-native:appsync:Resolver` use on the admin path.
- Association-status poll helper (read `MERGED` / `MERGE_FAILED` + detail) for
  failing-loudly in deploy output.

Each binding gets a minimal example under the binding package (untracked outputs per repo
convention).

## Phase 2 — Codegen: canonical shared types + colocation audit

- `GraphQL_FragmentGenerator`: stop stamping the `CommandResult` family into every
  mutation-bearing fragment; emit it **once** (admin, `@canonical`) and reference-only in
  plugin SDL. Same for Relay base types (`stampSharedIamTypes` retires; the admin source
  owns `PageInfo` + IAM-stamped shared types).
- `GraphQL_Stitcher`'s leading-name dedupe is no longer the merge mechanism — its stitch
  role ends at cutover (Phase 5); until then both paths coexist behind the deploy flag.
- **Audit every `@aws_subscribe` producer** for cross-source fan-in
  (`AdminApi.res` fan-in is safe — colocated; `Plugin_SubscriptionSchema` Source-C
  subscriptions are safe by construction). Any cross-plugin fan-in found → restructure or
  document as unsupported before Phase 4.
- Neutral-SDL emission (shipped increment 2a) is reused as-is: source-API SDL = neutral SDL
  + AWS dialect decoration.

## Phase 3 — Platform stack: merged APIs + admin as canonical source

- Platform stack creates the **Domain merged API** (+ **Platform merged API** in split
  mode), each with `mergedApiExecutionRole` (`appsync:SourceGraphQL` on associated sources).
- The admin base becomes an ordinary **source API** — `GraphQLApi` + declarative
  `GraphQLSchema` + resolvers — canonical owner of shared types, `Platform_*` fields,
  Plugins RM queries, and (per the Phase-0 decision) the `node` field. Its
  `SourceApiAssociation` targets the Platform merged API.
- **StackReference** exports the merged API ARN(s) + primary-auth contract for plugin
  stacks — this replaces the SigV4 `RegisterApiFragment` handshake as the cross-stack
  wiring.
- Merged-API auth: Cognito primary + IAM secondary (spike-validated); source APIs must use
  a compatible primary mode — encode that as a checked invariant, not a convention.

## Phase 4 — Plugin stack: own source API + association

Per-plugin (and per-standalone-service) stack shape (analysis § 11):

```
GraphQLApi (source) → GraphQLSchema (own neutral SDL + dialect)
  → DataSources/Functions/Resolvers (depend on GraphQLSchema — intra-stack ordering)
  → SourceApiAssociation (AUTO_MERGE, depends on schema + resolvers)
  → association-status poll (fail deploy loudly on MERGE_FAILED)
```

- Removes from the plugin deploy: fragment computation, the SigV4 caller
  (`registerFragmentViaApi`), the `ApiFragmentDeregistration` destroy-path dynamic
  provider, and the push waiter. The `schemaPushed` cross-stack gate becomes an ordinary
  intra-stack resource dependency.
- `pulumi destroy` deletes the association + source API — retirement by construction.
- Gate behind a deploy-mode flag so the shipped push path remains the default until
  Phase 5; `examples/online-shop-hybrid` (the CI-deployed stack) is the validation target.

## Phase 5 — Cutover + retire the push machinery

Once a full merged-mode deploy of the CI example is green end-to-end (deploy → mutation →
subscription → query through the merged endpoint, both auth modes):

- Flip the deploy default to merged mode; wipe alpha stacks (no migration code).
- Retire: the ApiFragmentRegistry aggregate + ApiFragments RM, the reactive
  ApiSchemaPush SideEffect, the deploy caller + `Platform_ApiFragments` status query +
  waiter, `Api_Adapter.updateSchema` as the AWS push path, and the runtime re-stitcher's
  push role. (`GraphQL_Stitcher` remains only if the local platform still composes with it
  — see Phase 6.)
- The UiFragmentRegistry and Plugin aggregate are untouched.

## Phase 6 — Local parity (option b, alongside scope-2)

Model each plugin as an independent executable subschema composed via `@graphql-tools`
(`mergeSchemas`/`stitchSchemas`), so both platforms share the plugin=subgraph,
platform=merge model:

- Requires lifting resolver closures out of the `DomainGraphQL_Server` module-level
  singleton — exactly the scope-2 decoupling in
  `Backlog/harmonize-local-deploy-lifecycle.md`; do them together.
- Preserve request-context propagation across subschemas (auth is resolver/context-layer,
  `Auth_GraphqlContext.res`).
- Local keeps its natively push-free behavior throughout; this phase is fidelity, not
  feasibility, and can trail Phase 5 without blocking it.

## Risks / open points

1. **10-source-API default cap** — limit increase filed after the spike; if AWS caps hard,
   a bounded-plugins-per-merged-API design is needed (open point).
2. **`MERGE_FAILED` is silent at runtime** — a failed source is live-but-unmerged. The
   deploy-time poll catches deploy-caused failures; consider surfacing association health
   on the platform later (explicitly *not* a registry component — analysis § 9).
3. **Coarse non-top-level auth** on the merged endpoint (per-source-ARN below the root) —
   validate against the authorization model during the spike; `@hidden` is the escape
   hatch.
4. **Relay `node`** — the one place merge is strictly less expressive than the stitcher;
   gated in Phase 0.
5. **Both paths coexist during Phases 2–4** — codegen must emit correct SDL for both the
   stitch path and the canonical/reference-only merge path until cutover.
