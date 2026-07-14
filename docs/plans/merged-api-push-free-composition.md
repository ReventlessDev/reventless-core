# Push-free schema composition via merged APIs

**Status:** IN PROGRESS — Phase 0 spike executed 2026-07-14: **GO** (all four gates
validated on real AWS; findings + the `node` decision recorded in Phase 0 below)
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
| Relay `node` | **DECIDED (Phase 0): field-resolver indirection (c) — confirmed working on AWS**; fallback (a) not needed; (b) remains rejected | § 12 + Phase 0 results |
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

### Phase 0 results (executed 2026-07-14, eu-west-1, alpha account) — **GO**

Spike shape: one Domain merged API (Cognito primary + IAM secondary,
`mergedApiExecutionRole` with `appsync:SourceGraphQL` + `appsync:StartSchemaMerge`) ←
admin source API (canonical shared types, `node`, `Platform_ping @aws_iam
@aws_cognito_user_pools`) + two plugin source APIs (Product / Order; own mutation returning
`CommandResult`, own Source-C subscription; NONE data sources, APPSYNC_JS resolvers).
Shared types mirrored the real emission (`GraphQL_FragmentGenerator.commandResultSdlTypes`
+ `Node`/`PageInfo`). Throwaway Pulumi TS program (classic `@pulumi/aws` v7); stack
destroyed after validation.

1. **Shared-type merge — PASS, with a semantics correction.** Identical copies +
   `@canonical` on the admin defs merged cleanly (`@canonical` accepted by
   `StartSchemaCreation` with no directive declaration needed). **`@canonical` SHADOWS
   divergent non-canonical copies instead of failing the merge**: flipping plugin B's
   `CommandAccepted.eventCount` to `String` kept the association `MERGE_SUCCESS` and the
   merged schema on the canonical `Int!`. A true `MERGE_FAILED` needs two *non-canonical*
   conflicting definitions (provoked with a `SharedThing` type in A=`Int` vs B=`String!`):
   only the later-merging association failed, admin + the other plugin stayed green, and
   the detail is precise (`Unable to resolve conflict on object with name SharedThing.x:
   Merging is not supported for fields with different types.`). Consequence for Phase 2:
   plugin-emitted copies of admin-owned shared types cannot break the merge — the
   canonical/reference-only discipline is for cleanliness, not merge safety; the real
   `MERGE_FAILED` surface is same-named non-shared types across plugins (already mitigated
   by plugin-prefix naming conventions).
2. **Relay `node` via field-resolver indirection (c) — PASS, low ceremony.** Admin's thin
   `node` resolver (NONE data source) returned `{id, __typename}` stubs for types the
   admin schema does not define; `node(id:"Product:77") { ... on Product { name } }` and
   the `Order` equivalent both resolved the concrete fields through the **owning plugin's
   field resolvers, cross-source**, via the merged execution role. **Decision: (c) is
   adopted.** Codegen cost: entity fields reachable through `node` need field resolvers in
   the owning source API (the stub only carries `id`/`__typename`); the per-type dispatch
   convention is Phase-2/4 design work.
3. **Per-plugin Source-C subscriptions — PASS.** Both plugins' `on<Mutation>(id: ID):
   CommandResult @aws_subscribe` fields merged and fired end-to-end over the merged
   realtime endpoint (Cognito WebSocket, union payload intact, no subscription resolvers
   needed).
4. **Cognito + IAM dual auth — PASS, exact semantics preserved.** SigV4 and Cognito both
   reached the `@aws_iam @aws_cognito_user_pools` field through the merged endpoint; IAM
   was correctly denied (`Unauthorized`) on Cognito-only fields — per-field multi-auth
   directives survive the merge verbatim (confirmed in the merged introspection SDL).

Operational findings:

- **Association creation is serialized per merged API**: concurrent
  `AssociateSourceGraphqlApi` calls 409 (`ConcurrentModificationException`). Creation-time
  only (not per schema change); plugin stacks must retry-with-backoff on 409 — for
  first-deploy concurrency of N new plugins — or the platform docs note it. The spike
  serialized via `dependsOn`.
- **Auto-merge fires on source schema updates within seconds** (~12 s from schema update
  to the new field serving on the merged endpoint). A canonical-shadowed divergence is a
  **silent no-op** (no status change, no `lastSuccessfulMergeDate` bump). Conflict
  detection on a real conflict was also ~seconds (`MERGE_SCHEDULED` → `MERGE_FAILED`).
- **`MERGE_FAILED` leaves the last-good merged schema serving** — the failed source's
  previously-merged fields keep working (stale, not vanished); only the new change is
  withheld. Recovery after reverting the conflict: `MERGE_SUCCESS` in ~11 s (auto).
- **Quota**: `L-3B7F188C` "Source API associations per Merged API", default 10,
  adjustable; increase to 25 filed 2026-07-14 (request
  `a4a902220b0948fe86001c77c8e5f74cemYQeVH7`, status PENDING).
- Classic `@pulumi/aws` already covers everything Phase 1 needs: `GraphQLApi.apiType` /
  `mergedApiExecutionRoleArn`, inline `schema` on the source `GraphQLApi` (declarative —
  provider runs `StartSchemaCreation` + poll internally), and
  `aws.appsync.SourceApiAssociation` (arg is `sourceApiAssociationConfigs: [{mergeType}]`,
  plural). The separate `GraphQLSchema` resource sketch in Phase 1 can collapse onto the
  existing `GraphQLApi` binding's `schema` field.
- The `@aws_subscribe` colocation audit (Phase 2 precondition) was completed alongside the
  spike: the only fan-ins are admin-owned (`onUIFragmentChange` ← 3
  `Platform_UIFragment*`, `onPluginStatusChange` ← `Platform_PluginStatusChanged`, all in
  the admin source) and per-plugin Source-C fields (own mutations by construction). **No
  cross-source fan-in exists.**

## Phase 1 — Pulumi bindings (`rescript-pulumi-aws`)

Net-new bindings (grep-confirmed absent; analysis § 11). Phase 0 confirmed the classic
`@pulumi/aws` provider covers all of these (see Phase 0 operational findings), so this
phase is pure ReScript binding work against known-good provider surface:

- ~~Extend `GraphQLApi` with `apiType` (`GRAPHQL` | `MERGED`) + `mergedApiExecutionRole`.~~
  **DONE 2026-07-14** — `AppSync_GraphQLApi.res` gained `apiType` +
  `mergedApiExecutionRoleArn`.
- ~~`aws.appsync.GraphQLSchema` — the declarative per-source-API schema resource~~
  **Collapsed onto the existing binding**: the classic provider's `GraphQLApi.schema`
  field IS the declarative schema (provider runs `StartSchemaCreation` + poll
  internally — spike-validated), and the binding already had it. No separate resource
  needed.
- ~~`aws.appsync.SourceApiAssociation`~~ **DONE 2026-07-14** —
  `AppSync_SourceApiAssociation.res` (classic provider, not `aws-native`: the spike
  validated the classic resource end-to-end; arg is `sourceApiAssociationConfigs`
  plural). Doc comment carries the create-time 409-serialization caveat.
- Association-status poll helper (read `MERGE_SUCCESS` / `MERGE_FAILED` + detail) for
  failing-loudly in deploy output — **moved to Phase 3/4**: it is an AppSync **SDK**
  call (`GetSourceApiAssociation`), and the `@aws-sdk/client-appsync` bindings live in
  `reventless-aws` (`AppSync_Adapter.res` precedent), not in the Pulumi binding package.

Compile-only example `src/example/MergedApiExample.res` (untracked outputs per repo
convention) exercises all three surfaces together; package builds with zero warnings.

## Phase 2 — Codegen: canonical shared types + colocation audit

- `GraphQL_FragmentGenerator`: stop stamping the `CommandResult` family into every
  mutation-bearing fragment; emit it **once** (admin, `@canonical`) and reference-only in
  plugin SDL. Same for Relay base types (`stampSharedIamTypes` retires; the admin source
  owns `PageInfo` + IAM-stamped shared types).
- `GraphQL_Stitcher`'s leading-name dedupe is no longer the merge mechanism — its stitch
  role ends at cutover (Phase 5); until then both paths coexist behind the deploy flag.
- ~~**Audit every `@aws_subscribe` producer** for cross-source fan-in~~ **DONE in
  Phase 0**: only admin-owned fan-ins (colocated in the admin source) and per-plugin
  Source-C fields exist — no cross-source fan-in; nothing to restructure.
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

1. **10-source-API default cap** — increase to 25 filed 2026-07-14 (PENDING; Phase 0
   findings). If AWS caps hard, a bounded-plugins-per-merged-API design is needed (open
   point).
2. **`MERGE_FAILED` is silent at runtime** — Phase 0 refined this: the failed source's
   *previously merged* fields keep serving from the last-good merged schema (stale, not
   vanished); only the new change is withheld. The deploy-time poll catches deploy-caused
   failures; consider surfacing association health on the platform later (explicitly
   *not* a registry component — analysis § 9).
3. **Coarse non-top-level auth** on the merged endpoint (per-source-ARN below the root) —
   Phase 0 confirmed root-field multi-auth directives merge and enforce exactly (incl.
   deny); below-root granularity still needs a check against the authorization model when
   real read models land (Phase 4); `@hidden` is the escape hatch.
4. ~~**Relay `node`**~~ — resolved in Phase 0: option (c) confirmed; the merged model is
   no longer less expressive than the stitcher for anything Reventless emits.
5. **Both paths coexist during Phases 2–4** — codegen must emit correct SDL for both the
   stitch path and the canonical/reference-only merge path until cutover. Softened by the
   Phase-0 finding that canonical shadowing makes shared-type drift merge-safe.
6. **Association creation 409s under concurrency** (Phase 0 finding) — first-time
   `AssociateSourceGraphqlApi` calls against one merged API are serialized by AWS;
   concurrent *initial* plugin deploys need retry-with-backoff in the association step
   (steady-state schema updates are unaffected).
