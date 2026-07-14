# Push-free schema composition via merged APIs

**Status:** COMPLETE 2026-07-14 — all phases done. Phases 0–5: cutover pushed +
CI-green, push machinery retired across all four packages and applied to the live
alpha platform; Relay `node` open item resolved by dropping the root field on AWS
(see the resolution section); Phase 6: local plugin=subgraph composition landed.
Follow-ups live in "Risks / open points" (quota increase pending; association-409
backoff documented-only; below-root auth granularity check when real read models
land).
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
| Relay `node` | **REVISED post-retirement: root field dropped on AWS (fallback (a))** — Phase 0 proved (c) *feasible*, but the retirement investigation showed `node()` never worked on deployed AWS and has zero consumers; `Node` interface + global IDs stay (see "Relay `node` resolution" below) | § 12 + Phase 0 + resolution section |
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

- ~~stop stamping the `CommandResult` family into every mutation-bearing fragment /
  reference-only in plugin SDL~~ **Inverted by the Phase-0 findings**: every source API
  schema must be **valid standalone** (`StartSchemaCreation` rejects a document that
  references undefined types), so plugin sources **keep** their identical copies of the
  shared types — `GraphQL_FragmentGenerator` needs **no change**. Ownership is expressed
  on the admin side instead: `@canonical` on the admin source's copies makes them win
  over any plugin copy (divergence is shadowed, not failed — spike-validated).
  **DONE 2026-07-14:**
  - core `GraphQL_Stitcher.stitchStandalone(~fragment)` — renders one fragment as a
    self-contained subgraph document (relay base types included, global `node` query
    omitted; only the canonical base document carries `node`). `stitch` is unchanged
    (both delegate to the same assembly).
  - `reventless-aws` `AppSync_SdlDecorate.stampCanonicalTypes` — stamps `@canonical` on
    `PageInfo`, the `CommandAccepted/Rejected/Pending` types, `interface Node`, and
    `union CommandResult`; composes after `stampSharedIamTypes`; admin-source-SDL only.
  - Tests in `GraphQL_StitcherTest` + `AppSync_SdlDecorateTest`.
  Per-source SDL assembly for real deploys (admin = `stitch` of the auth-decorated base
  + `stampCanonicalTypes`; plugin = `stitchStandalone` + `injectAwsSubscribe` with its
  own sources) is wired in Phases 3–4 where the stacks consume it.
- `GraphQL_Stitcher`'s leading-name dedupe is no longer the merge mechanism — its stitch
  role ends at cutover (Phase 5); until then both paths coexist behind the deploy flag.
- ~~**Audit every `@aws_subscribe` producer** for cross-source fan-in~~ **DONE in
  Phase 0**: only admin-owned fan-ins (colocated in the admin source) and per-plugin
  Source-C fields exist — no cross-source fan-in; nothing to restructure.
- Neutral-SDL emission (shipped increment 2a) is reused as-is: source-API SDL = neutral SDL
  + AWS dialect decoration.

## Phase 3 — Platform stack: merged APIs + admin as canonical source

**DONE 2026-07-14** — all behind a new `mergedApi: bool` on `Platform.MakeWithConfig`
(reventless-aws; default `false` in `Make()` — the push path stays the default until
Phase 5). Supported with `deployPlatform` only; `makePlatform` and `deployPlugin` fail
loudly under the flag (`deployPlugin` unlocks in Phase 4). All stacks of one platform
must agree on the flag.

- ~~Domain merged API (+ Platform merged API in split mode) with execution role~~ —
  `AppSync_MergedApi.res` (components/Api): merged `GraphQLApi` (Cognito primary + IAM
  secondary via `Auth_Cognito`, `apiType: MERGED`) + `merge-exec-role`
  (`appsync:SourceGraphQL` + `appsync:StartSchemaMerge`; unscoped resources — source
  APIs associate later from independent plugin stacks, so their ARNs can't be
  enumerated at platform-deploy time), `associateSource` (AUTO_MERGE), and
  `mergeStatusGate`.
- ~~Admin base as ordinary source API with declarative schema~~ —
  `AppSync_Adapter.makeSourceApiResource(~schema)` puts the SDL inline on the
  `GraphQLApi` resource (the Phase-1 finding: `schema` IS the declarative
  GraphQLSchema); the provider's internal StartSchemaCreation+poll orders resolvers
  after schema-ACTIVE, so `preAdminResolversSchemaHook` simply returns the barrier in
  merged mode (no push). Admin source SDL = push-path assembly + `stampCanonicalTypes`.
- **Split-mode addition the plan hadn't spelled out:** the Domain merged API also needs
  a platform-owned canonical source (relay base types + the global `node` query —
  plugin subgraphs omit both). The existing `DomainApi` resource carries this
  relay-base document declaratively; the admin document goes on `PlatformApi` →
  Platform merged API. Unified mode: single source carries the admin document → Domain
  merged API.
- ~~StackReference exports~~ — `domainMergedApi{Arn,Id,Endpoint}`,
  `platformMergedApi{Arn,Id,Endpoint}` (== domain in unified mode), and
  `mergedApiPrimaryAuth` (the primary-auth contract). The ARN exports are folded
  through the merge-status gate (`GetSourceApiAssociation` poll, SDK helper
  `AppSync_Adapter.waitForMergeSuccess` — the association-status helper deferred from
  Phase 1 landed here): `MERGE_FAILED` fails `pulumi up` with AWS's status detail.
- ~~Primary-auth invariant~~ — `AppSync_Adapter.primaryAuthenticationType` constant +
  `AppSync_MergedApi.assertCompatiblePrimaryAuth`, asserted where associations are
  created; plugin stacks re-assert against the `mergedApiPrimaryAuth` export (Phase 4).
- Client-facing endpoints (host-UI `config.json`, `onPlatformDeployed`) resolve to the
  **merged** endpoints under the flag; the source-API exports stay unchanged for
  coexisting push-path stacks.
- Validated: reventless-aws unit tests (canonical source documents, merge poll) + local
  `pulumi preview` of `examples/online-shop-hybrid/platform-aws` against alpha in both
  modes — flag off: zero API-surface changes (pure refactor); flag on: exactly the
  8 new resources (2 merged APIs, 2 exec roles, 2 policies, 2 associations) +
  `+schema` on both source APIs + merged endpoints in `config.json`.

## Phase 4 — Plugin stack: own source API + association

**DONE 2026-07-14** — same `mergedApi` flag as Phase 3; the push path stays the
default and is byte-identical when the flag is off (preview-verified).

Realized stack shape (one timing correction vs the sketch: the plugin's fragment is
only computable during `P.make()`, so the source API is created schema-less and the
subgraph document is pushed by the hook — the plugin's own API is a single writer by
construction, so this push has none of the old path's coordination problems):

```
GraphQLApi (source, schema-less; user pool from the platform's cognito* exports)
  → preResolversSchemaHook pushes stitchStandaloneWithAwsDirectives(fragment)
    to the OWN source API (StartSchemaCreation + ACTIVE poll)
  → DataSources/Resolvers chain on the returned Output (unchanged mechanism —
    the schemaPushed gate is now intra-stack, no cross-stack handshake)
  → SourceApiAssociation (AUTO_MERGE, sequenced behind the schema push;
    merged API referenced by the platform's domainMergedApiArn /
    platformMergedApiArn export, selected by ~apiTarget)
  → mergeStatusGateWith poll folded into the `sourceApiAssociationId` export
    (MERGE_FAILED fails the deploy with AWS's status detail)
```

- In merged plugin mode the own source API fills all four API slots the push path
  fills with StackReference phantoms — resolver/data-source wiring is untouched and
  re-targets automatically. The Cognito pool comes from the platform's
  `cognitoUserPoolId`/`cognitoRegion` exports (no pool/client provisioning in plugin
  stacks); the `mergedApiPrimaryAuth` contract is asserted where the association is
  created (fails loudly, incl. when the platform stack isn't merged-deployed yet).
- Skipped on the merge path: `registerFragmentViaApi` (SigV4), the
  `ApiFragmentDeregistration` destroy-path provider, the `Platform_ApiFragments`
  waiter, and the introspection drift check. `pulumi destroy` deletes the
  association + source API — retirement by construction.
- New exports: `pluginSourceApiId`, `pluginSourceApiEndpoint`,
  `sourceApiAssociationId` (gated on the merge poll).
- Association 409s under first-deploy concurrency surface as a deploy failure to
  retry (documented on the binding + in Platform.res) — no in-provider backoff.
- Validated: 234 reventless-aws tests (incl. subgraph-document shape: relay types,
  no `node`, `@aws_subscribe`, no `@canonical`); `pulumi preview` of
  `catalog-aws` — merged mode plans the own source API + role, re-targets the
  DataSources' `apiId`, provisions no pool/client, performs no SigV4 registration,
  and fails loudly on the missing merged exports (alpha's platform is push-mode);
  flag-off preview is API-surface neutral.
- **Open items for Phase 5:** (a) full happy-path association can only be exercised
  against a merged-deployed platform — the CI example flip is that validation;
  (b) `node` cross-source field resolution (Phase-0 option (c)) needs the per-type
  field-resolver dispatch on plugin sources — track as part of the cutover checks;
  (c) on FIRST deploy the association may briefly serve fields whose resolvers are
  still attaching (association depends on schema, not resolvers) — masked in
  practice by the plugin connect handshake gating Active status.

## Phase 5 — Cutover + retire the push machinery

**Cutover EXECUTED + validated on real AWS 2026-07-14** (retirement still pending, below):

- **Cutover mechanism = the default flip**: `Platform.Make()` now sets
  `mergedApi = true`, so every generated deploy program (generate-plugin owns
  Main.res and cannot express MakeWithConfig) is merged-mode by default. No
  per-stack config override exists — only alpha stacks of the hybrid example
  were deployed, so there was nothing to scope a gradual flip away from; the
  legacy push path remains reachable solely via explicit
  `MakeWithConfig({let mergedApi = false})` until retirement deletes it.
  (A transient `platform:mergedApi` stack-YAML override was used to stage the
  first merged deploys and was removed the same day.)
- **Alpha wiped** (all three stacks destroyed — also load-bearing, not just the
  data convention: an in-place flip would let the old plugin stacks'
  `ApiFragmentDeregistration` providers fire deregisters on removal → the still-
  deployed reactive push would clobber the new declarative source schemas).
  Recurring destroy nuisance: SQS QueuePolicy deletes race their parent queue
  ("couldn't find resource") — retry the destroy / `pulumi state delete` the
  orphan policy.
- **Merged-mode deploys green** (platform 188 res / catalog 141 / ordering 160,
  zero errors; plugin subgraph push→ACTIVE ~2 s; all four associations
  MERGE_SUCCESS — the in-deploy merge gates passed).
- **E2E through the merged endpoints, both auth modes:**
  - merged Domain schema composes both plugins + relay base + `node`; per-field
    `@aws_auth(cognito_groups)` and `@aws_subscribe` (rewired to merged mutation
    names) survive; no-auth → UnauthorizedException;
  - Cognito: `Catalog_AddCategory` → CommandAccepted → `Catalog_Categories`
    serves the projected row ~10 s later; `Ordering_Customer_Register` →
    CommandAccepted through the same endpoint;
  - IAM: SigV4 (`Util_AppSync_Caller`) reached the `@aws_iam`-stamped
    `Platform_ApiFragments` through the Platform merged endpoint (empty — correct,
    nothing registers fragments in merged mode);
  - both plugins reach `Connected` (runtime connect handshake unaffected);
  - live WebSocket subscription not re-tested (Phase-0 spike covered it;
    directives verified in the merged introspection).
- **Confirmed open item:** `node()` returns null on the Domain merged API — the
  relay-base source carries the field but no resolver is provisioned on the
  domain side in merged mode, and concrete types need the per-type field-resolver
  dispatch (Phase-0 option (c) codegen). Track as its own work item; not a
  blocker for the composition path.
- **Deployed from the LOCAL build** — alpha now drifts from published packages
  until the next alpha push republishes + CI redeploys (also restores the host-UI
  custom domain, absent in local deploys). Push before relying on CI deploys.

**Phase-5 retirement — DONE 2026-07-14** (after the cutover push went CI-green: Release
published, layer rebuilt, CI redeploy kept all associations MERGE_SUCCESS):

- ~~Flip the deploy default~~ — `Make()` sets `mergedApi = true`; the `mergedApi`
  flag itself was then REMOVED (merged is the only path; `makePlatform` on AWS is a
  loud failwith pointing at deployPlatform/deployPlugin).
- ~~Retire the push machinery~~ — deleted across four packages (~2 800 net lines):
  - core: `ApiFragmentRegistry/` (aggregate + RM specs/behavior/projection),
    `Platform_ApiFragmentsApi`, `GraphQL_PushPlanner`, the `Api_Builder`/
    `Api_Operations`/`updateSchema` component chain (dead since Plugin_Builder only
    uses `generateFragment`), the stitcher's schema-clobber guard family
    (`rootTypeFieldNames`/`isCatastrophicSchemaShrink` — single writers need no
    shrink guard), AdminApi's registry mutation entries + `systemCallerFieldNames`.
  - infra: `module Api` dropped from `Platform.T`; `updateSchema` dropped from
    `Api_Adapter.Provider` (live surface = `generateFragment`).
  - aws: `ApiSchemaPush` (+ its runtime .mjs + SideEffectHandler wiring + the whole
    AllSideEffectHandlers Lambda — ApiSchemaPush was its only occupant),
    `ApiFragmentDeregistration`, `Platform_ApiFragments_Lambda`,
    `registerFragmentViaApi` + waiter, `planAwsPushes`, adapter
    `updateSchema`/`deploySchemaWithRetry`/`getIntrospectionSdl`, phantom
    API/StackReference plumbing (plugin stacks always own a source API now).
  - local: registry mirror wiring (LocalApiFragmentRegistryAggregate, ApiFragments
    RM, dispatch/resolver/self-heal blocks, deploy-time RegisterApiFragment),
    `LocalGraphQL_Adapter.updateSchema`, `DomainGraphQL_Server.rebuildSchema`.
- The UiFragmentRegistry and Plugin aggregate are untouched. `GraphQL_Stitcher`
  keeps `stitch`/`stitchStandalone`/`encode`/`decode` (canonical/subgraph document
  assembly) — the local platform composes in-process (Phase 6 unchanged).
- **Validated:** monorepo build zero warnings; 180 suites / 1 231 tests green;
  hybrid local platform live-boots (login + `Platform_UIFragments` +
  `Platform_Plugins` Connected); retirement applied to the live alpha platform —
  45 resources deleted (one SQS QueuePolicy-race retry), admin source schema
  shrank declaratively, auto-merge kept all four associations MERGE_SUCCESS,
  registry fields gone from the merged schema, plugin stacks resource-neutral.
- Still open: Phase 6. (`node` resolved below.)

## Relay `node` resolution — root field DROPPED on AWS (2026-07-14)

The Phase-0 decision adopted option (c) (thin canonical stub + field resolvers on
the owning source) on **feasibility** grounds. The retirement investigation
changed the cost/benefit picture with three findings:

1. **`node()` never worked on deployed AWS — including the entire push era.**
   `NodeResolver_AppSync` (a pipeline resolver decoding the global ID and routing
   to the right DynamoDB data source) was written and every read model registered
   its type into it at deploy time, but the final `make()` that would create the
   resolver was **never called anywhere**. Every deployed AWS platform has served
   `node()` as null since the field existed. (The Postgres path had a gated
   `createNodeResolver` variant — monolithic-only, likewise not exercised by any
   deployed stack.) The merged cutover therefore did not regress anything.
2. **Zero consumers.** reventless-ui (host shell + AutoUI) fetches exclusively
   through the typed surface — plural connections, single-ID queries, `ByIds`
   batches, and the `@resolves`/`@resolvesMany` cross-table hops. Nothing queries
   `node(`. That nobody ever noticed finding 1 is itself the evidence.
3. **Merged composition made (c) structurally expensive.** On the old single API
   the pipeline resolver would have worked (every table reachable from one API).
   Under merged APIs the `node` field lives in the platform-owned canonical
   source while the data lives in plugin stacks, so a real implementation needs
   either dynamic cross-stack data-source registration (re-creating exactly the
   registry coordination this plan retired) or per-FIELD resolvers on every
   plugin source for every node-reachable type (the stub only carries
   `id`/`__typename`) — a large codegen + resolver-count investment.

What `node()` *would* buy if implemented: Relay-client refetch/cache
normalization (relevant only if the UI moves to a Relay-style client), universal
"resolve any global ID" deep links (today served type-explicitly by
`@resolves`/`@resolvesMany`), and a generic fetch-by-ID tool for agents (MCP
currently generates typed per-read-model resources instead). All plausible,
none present.

**Decision:** a root field should either work or not exist. On AWS the canonical
documents no longer emit `node(id: ID!): Node` (both the admin document and the
split-mode Domain base document assemble via the standalone/subgraph path). The
**`Node` interface and global IDs stay** — they cost nothing and are exactly
what makes a future `node()` (or client-side normalization) possible without a
schema migration. The split-mode Domain base source carries a minimal
`Platform_ping: String` query field instead (a GraphQL schema cannot have an
empty Query type; unresolved → null, spike precedent). The local platform keeps
its working in-process `node()` (its resolver is self-contained in
`DomainGraphQL_Server`). Dead code deleted with the decision:
`NodeResolver_AppSync` + its type registration + the node pipeline functions in
the `rescript-pulumi-aws` resolver bindings, and the Postgres deploy-time node
resolver creation (`createNodeResolver`/`nodeResolverCode`; the Pg Lambda's
self-contained runtime `handleNode` stays inert pending a future consumer).
**Revisit trigger:** a real consumer (Relay client adoption, generic deep links,
agent generic-fetch) — then implement (c) scoped to the types that need it, not
everything.

## Phase 6 — Local parity (option b, alongside scope-2)

**DONE 2026-07-14.** Each plugin is now an independent subschema on the local domain
server, composed at start — both platforms share the plugin=subgraph, platform=merge
model:

- `DomainGraphQL_Server` replaced its flat module-singleton registries with
  **per-scope buckets** (`setScope`/`resetScope`/`relabelScope`, default scope
  `"platform"`; scope functions are DomainGraphQL_Server-only — the shared
  `GraphQL_ServerInstance.t` interface is unchanged). Platform.res scopes each
  plugin's construction (token → construct → relabel to the plugin name) in both
  `makePlatform` and `deployPlugin`; admin/platform registrations stay in the
  platform bucket. This is the scope-2 "lift out of the singleton" decoupling —
  registrations are now plugin-attributed and per-plugin resettable.
- **Standalone validation per plugin bucket** (mirrors AWS source-API validity):
  each plugin bucket is seeded with the relay base types (as `stitchStandalone`
  embeds them per subgraph) and its document is built + `createSchema`-checked in
  isolation before composition — failure names the plugin
  (`Plugin "<name>" subgraph document is not valid standalone: …`), exactly the
  attribution a failed plugin-stack deploy gives on AWS.
- **Composition = @graphql-tools merge**: the final schema is built with
  `createSchemaMulti` (new array-form binding in rescript-graphql-yoga —
  makeExecutableSchema's `typeDefs`/`resolvers` arrays, i.e.
  mergeTypeDefs/mergeResolvers) from one document + one resolver map per bucket.
  Identical shared-type copies dedupe; a same-field/different-type conflict throws
  (`Cross-plugin schema merge failed (mirrors AWS MERGE_FAILED): …`) — the same
  conflict semantics the Phase-0 spike measured on AWS (disjoint-field same-name
  types union silently there too). Shared CommandResult copies register per scope
  (the old global once-only guard is gone).
- Request-context propagation unchanged by construction: one yoga server, one
  `buildAuthContext` — no stitching gateway, no delegation layer (the plan's
  context risk applied to the `stitchSchemas` variant; merge avoids it). Local
  keeps its in-process `node()` (platform bucket).
- Validated: monorepo 181 suites / 1 236 tests green (5 new subschema tests:
  compose + cross-bucket resolution, standalone failure names the plugin,
  merge-conflict failure, reset, platform-only-type leakage caught standalone);
  hybrid platform-local live-boot green (login, `Platform_Plugins` Connected ×2,
  domain query through the composed schema).
- `Backlog/harmonize-local-deploy-lifecycle.md` is superseded: its
  register→push→wait staging mechanics were retired with the push machinery, and
  the "one mental model" value it argued for is delivered by this phase (see the
  note in that file).

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
