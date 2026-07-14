# Push-free schema composition via merged APIs (AppSync Merged APIs + yoga)

**Status:** Analysis
**Date:** 2026-07-13 (updated 2026-07-14)
**Relates to:** [docs/plans/done/event-sourced-fragment-registries.md](../plans/done/event-sourced-fragment-registries.md)
(the "Alternative design" section names AppSync Merged APIs as the out-of-scope push-free option);
[docs/analysis/fragment-registry-architecture.md](./fragment-registry-architecture.md) (§ 10–11 —
bootstrap push anatomy + provider-dialect audit).
**Update (2026-07-14):** the referenced plan is now **complete and deploy-validated** — all four
phases, including the Phase-4 `deploy-schema:*` retirement/cutover, landed green on alpha (commit
`af21a47f1`, plan moved to `docs/plans/done/`). The whole-replace stitch-and-push path therefore
**ships today**. That removes the "pivot before Phase 4" branch this analysis originally weighed
(§ 13): merged APIs are now unambiguously a **successor architecture** to a working push-based path,
not a mid-flight redirection. The feasibility findings and the merge-model design (§§ 2–12) are
unchanged; only the sequencing framing (§ 8, § 13) is affected.
**Plan:** [docs/plans/done/merged-api-push-free-composition.md](../plans/done/merged-api-push-free-composition.md)
(created 2026-07-14 from this analysis; Phase 0 spike is the go/no-go gate).
**Question:** Is a *push-free* architecture feasible — where each plugin is an independently
deployed sub-graph and the platform **merges** rather than **stitch-and-whole-replace-pushes** the
schema — on **AWS** (AppSync Merged APIs) and on the **graphql-yoga** local platform? Pros, cons,
consequences.
**Follow-ups (added 2026-07-13):** what merged composition means for the fragment *registry*
itself (aggregate vs DCB — § 9); the exact anatomy of a single-plugin schema update and where
the AppSync call actually lives (§ 10); and concrete sketches — the plugin-stack Pulumi resource
graph + net-new bindings (§ 11), and the admin base as a canonical source API incl. the Relay
`node` decision (§ 12).

---

## 1. The problem this would dissolve

Every piece of machinery the fragment-registry plan builds exists to make **N concurrent deploys
safely write one whole-replace schema** to a single AppSync API:

- the `deploy-schema:*` keyspace + paginated scan + stitch;
- the `withSchemaPushLock` lease, the hash rows, the drift-repair, the catastrophic-shrink guard;
- the reactive single-writer (mjs or SideEffect), the singleton-aggregate registry, the deploy
  caller + status query + waiter;
- the **retirement gap** (name-keyed rows with no removal path — analysis § 7);
- the **concurrent-push API-lock race** (`Schema is currently being altered` — deploy-#4).

All of it is a consequence of one design choice: **the schema is one artifact, replaced wholesale,
by many writers.** A merge-based model removes that choice. Each plugin owns its own schema; the
platform *composes* the pieces. There is no whole-replace, so there is no writer to coordinate, no
lock to race, no lease, no shrink guard, and no orphaned-field retirement gap.

## 2. The two target models

| | AWS | Local (yoga) |
|---|---|---|
| Mechanism | **AppSync Merged API** — build-time composition of *source APIs* into one read-only merged endpoint (`SourceApiAssociation`, auto- or manual-merge) | in-process schema composition via `@graphql-tools` (`mergeSchemas`/`stitchSchemas`) — or the status-quo "register all fields into one executable schema", which is *already* a build-time merge |
| Sub-graph = | one source AppSync API per plugin (own schema + resolvers + data sources, own stack) | one executable subschema per plugin (typeDefs + resolver map) |
| Composition is | AWS-managed, out-of-band, async (merge status per association) | synchronous, in-process (rebuild the served schema) |
| "Push" | **none** — merged schema is read-only, derived from sources | **none** — there was never a push locally; schema is built in-process |

**Key asymmetry:** the local platform is *already* push-free — `DomainGraphQL_Server.rebuildSchema`
composes an executable schema in-process from per-plugin resolver registrations. So "push-free" is
native locally; the only question there is whether to model plugins as **independent subschemas**
(true parity with the AWS subgraph model) or keep the current single-schema registration. On AWS the
change is real: a different resource model (merged + source APIs) replacing `StartSchemaCreation`.

## 3. How Reventless maps onto merged composition

- **plugin → source API.** Each plugin deploys its own AppSync API carrying only its own
  types/fields/resolvers/data sources. This is close to what a plugin stack already builds, minus the
  cross-plugin stitch.
- **admin base → a source API (the seed / canonical owner of shared types).** `AdminApi.baseFragment`
  becomes the schema of an "admin" source API. Platform-aggregate mutations, Plugins-RM queries, the
  `Platform_*` fragment-registry mutations/queries, and the Relay/shared traversal types all live
  there, owned canonically.
- **split vs unified → two merged APIs vs one.** Split mode: a **Domain** merged API (source APIs =
  domain-target plugins) + a **Platform** merged API (source APIs = admin base + platform-target
  plugins). Unified: one merged API, all sources. The `apiTarget = Domain | Platform` dimension the
  plan added maps directly to "which merged API is this plugin a source of." There is a **precedent**:
  `Config.splitApi` already routes Domain vs Platform to *separate AppSync APIs* today
  (`GraphQL_PushPlanner`/`AppSync_SdlDecorate.planAwsPushes`) — but it does so by **re-stitching two
  whole schemas and whole-replace-pushing each**, which is precisely the model merged APIs replace.
- **deploy → create/update the plugin's own source API + association** (auto-merge propagates it).
- **retire / `pulumi destroy` → delete the source API / association** → its fields vanish from the
  merged schema automatically. **The retirement gap is solved by construction** — no
  `DeregisterApiFragment`, no destroy-path dynamic provider, no symmetric-deregister reasoning.

## 4. AWS feasibility — AppSync Merged APIs

**Authoritative constraints** (AWS AppSync Merged API docs, retrieved 2026-07-13):

- **Composition model:** build-time. Merged schema is **read-only**; changes originate in source
  APIs. Auto-merge propagates a source change unless it introduces an unresolvable conflict, which
  sets the association to `MERGE_FAILED` (error readable via `GetSourceApiAssociation`). Manual merge
  via `StartSchemaMerge`.
- **Limits:** default **10 source APIs per merged API** (soft — limit-increase available); merged
  schema doc ≤ **10 MB**; a source API can associate with **only one** merged API; a merged API
  **cannot** itself be a source API.
- **Conflict resolution:** root types (`Query`/`Mutation`/`Subscription`) **union** their fields
  automatically — this is the core mechanism that replaces the stitcher's field concatenation. For
  non-root types: no-directive conflicting definitions **union their fields** if compatible, but a
  field with the **same name and different type → merge fails** (`Merging is not supported for fields
  with different types`). Directives resolve conflicts: **`@canonical`** (this source's def wins),
  **`@hidden`** (exclude from merge), **`@renamed(to:)`** (avoid a name clash). **Two source
  resolvers on the same field → error** — requires the "field-resolver pattern" (the second source
  owns a distinct sub-type).
- **Subscriptions:** *"All subscription operations defined in your associated source APIs will
  automatically merge and function… without modification."* Subscriptions merge and work — but
  `@aws_subscribe(mutations: [...])` references mutation **field names within its own source API's
  schema**. So a subscription and every mutation it fans in from must live in the **same source API**.
- **Auth:** the merged API owns its auth config; at merge time a source API's **primary** auth mode
  must be the merged API's primary *or* a secondary mode, else the merge fails. Multi-auth directives
  on source fields (`@aws_auth`, `@aws_iam`) **merge automatically**. A `mergedApiExecutionRole` with
  `appsync:SourceGraphQL` is required; top-level fields authorize per-field, **non-top-level fields
  authorize coarsely at the source-API-ARN granularity** (or hide with `@hidden`).

**What maps cleanly:**

- The `apiTarget` split, plugin isolation, and standalone services (a standalone service is just
  another source API — the plan's standalone-services goal becomes trivial and needs no registration
  mutation at all).
- **Dual-auth system caller** (Cognito + IAM): configure the merged API with Cognito primary + IAM
  secondary; keep per-field `@aws_iam` on the source API's `Platform_*` fields — multi-auth directives
  merge automatically. (This also removes the whole `extractLeadingName`/`injectAwsAuthAll` dual-auth
  bug surface from deploy-#4 — auth is per-source-API and merged by AWS.)
- **Ordering gate** (`schemaPushed` → `CreateResolver`) becomes **intra-source-API**: a plugin's
  schema and its resolvers are the same API's concern, co-deployed in the plugin's own stack. No
  cross-stack push-then-create-resolver coordination.

**Where the real work / risk is:**

1. **Pulumi bindings do not exist yet.** The repo's `rescript-pulumi-aws` has bindings for
   `GraphQLApi`, `DataSource`, `Resolver`, `Function` — but **none for `SourceApiAssociation` or a
   `MERGED`-type API** (grep confirms). These are hand-written ReScript bindings today, so the merged
   + source-association resources must be added (the underlying Pulumi AWS/AWS-native providers do
   support them; this is binding work, not a provider gap).
2. **Shared-type ownership becomes an explicit contract.** Today `GraphQL_Stitcher` prepends Relay
   base types and dedupes by leading name (`GraphQL_Stitcher.res:164-172`), the `CommandResult`
   union family (`CommandAccepted/Rejected/Pending`) is emitted into *every* mutation-bearing fragment
   (`GraphQL_FragmentGenerator.res:13-28`), and `stampSharedIamTypes` stamps `PageInfo` + that family
   **once** on the assembled SDL (analysis § 10). Under merge, these shared non-root types must be
   either **defined identically in every source API** (union of identical fields is fine) or **owned
   `@canonical` by the admin source and stubbed elsewhere**. A single field-type divergence flips the
   association to `MERGE_FAILED`. This trades the stitcher's silent dedupe for AWS's stricter merge +
   a discipline the codegen must enforce (emit shared types canonically from one source, `@hidden`/
   stub in others).
3. **The Relay `node` field is a sharp, specific blocker.** The stitcher injects a single global
   `node(id: ID!): Node` query, and **every plugin registers its own return types into that one
   `node` resolver's registry** (`QueryDbResolvers_AppSync.registerNodeType`; local
   `DomainGraphQL_Server.registerNodeType`). AppSync Merged APIs **forbid multiple source resolvers on
   the same field** — so `node` cannot be co-resolved across source APIs. Options, all with cost:
   drop the global `node` field (Relay-compliance regression); give one source API a `node` resolver
   with access to every plugin's data source (breaks plugin isolation — the very thing the split
   buys); or make `node` a thin field-resolver-pattern indirection. This is the single most concrete
   thing the merge model breaks and needs a decision up front.
4. **Subscription fan-in must be colocated.** The admin base's `onUIFragmentChange ← 3 mutations`
   fan-in (analysis § 11; `AdminApi.res:92-99`) is fine *iff* those mutations live in the admin source
   API (they do). But the pattern is a landmine: any subscription whose triggering mutations are spread
   across plugins cannot be expressed with `@aws_subscribe` across source APIs. Per-plugin "Source C"
   subscriptions (each linking to that plugin's own mutations, `Plugin_SubscriptionSchema.res:27-55`)
   are safe; cross-plugin fan-in is not. Needs an audit of every `@aws_subscribe` producer.
5. **Merge is async with its own failure surface.** The deploy waiter changes shape: instead of
   polling a custom push-status, poll the `SourceApiAssociation` status (`MERGED` vs `MERGE_FAILED` +
   detail) after `StartSchemaMerge`, or rely on auto-merge and surface `MERGE_FAILED` in deploy
   output. Better DX than a timeout, but a new mechanism to build.
6. **Scaling ceiling.** 10 source APIs/merged API by default. A platform with many domain plugins
   (+ admin + platform-target plugins) will need a limit increase, or a design that keeps plugin count
   per merged API bounded. Hard ceiling to plan around; the current stitch model has no such per-API
   cap.
7. **Non-top-level field auth is coarse.** Fine-grained auth below the root is per-source-ARN, not
   per-field, on the merged endpoint — a behavioral difference from today's per-field `@aws_auth`
   everywhere. Likely fine (Reventless auth is mostly root-field + Admin-group gating) but must be
   confirmed against the authorization model.

## 5. Local (yoga) feasibility

Strictly easier — the local platform is already a build-time in-process merge:

- **Status quo already push-free.** `rebuildSchema` composes one executable schema from per-plugin
  resolver registrations (`CommandGeneratorResolvers_GraphQL` / `QueryDbResolvers_GraphQL` register
  each field *with* its resolver; yoga couples typeDefs+resolvers). There is no push to eliminate.
- **Two parity options:**
  - *(a) keep single-schema registration* — no change; local stays a merge-by-registration.
  - *(b) model each plugin as an independent executable subschema* and compose with
    `@graphql-tools` `mergeSchemas`/`stitchSchemas` for true structural parity with the AWS subgraph
    model. This aligns with the deferred **scope-2** work
    (`docs/plans/Backlog/harmonize-local-deploy-lifecycle.md`: decouple field-SDL from resolver
    registration, stage platform-then-plugin deploys). Concrete obstacle: today
    `DomainGraphQL_Server` is a **module-level singleton** where `registerMutations/Queries` bind
    typeDefs+resolvers together (`rebuildSchema` only merges *types*); fields cannot move to a
    per-plugin subschema without lifting their resolver closures out of that singleton — exactly the
    scope-2 decoupling. Auth is enforced at the **resolver/context layer**, not in SDL
    (`Auth_GraphqlContext.res`), so subschema composition must preserve request-context propagation
    across subschemas.
- **AWS's hard constraints are trivial locally:** shared-type canonicalization, subscription fan-in
  colocation, and the source-API cap are all in-process concerns with one executable schema — cross-
  type merging and cross-mutation subscriptions "just work" because there is no API boundary.
- **The neutral-SDL work (increment 2a) still pays off:** whichever option, local composes from
  neutral SDL + resolver functions; no `@aws_subscribe` stripping.

So on local the interesting question is *architectural fidelity*, not feasibility. Option (b) makes
the two platforms mirror each other (plugin = subgraph, platform = merge); option (a) leaves a
conceptual gap (AWS composes independent APIs; local composes registrations into one).

## 6. Pros

1. **Deletes the entire coordination problem, not just its symptoms.** No whole-replace → no lease,
   hash, drift-repair, shrink guard, reactive writer, singleton registry, deploy caller/waiter, or
   status query for the *push* purpose. The bulk of `event-sourced-fragment-registries.md` (API side)
   is unnecessary.
2. **Retirement gap solved by construction** — delete the source API, fields disappear. (This is the
   original motivating defect, § 7.)
3. **Concurrent-push race gone** — there is no shared whole-replace lock; plugins deploy their own
   source APIs independently and in parallel with no cross-plugin contention.
4. **True plugin isolation & independent deploy velocity** — the property AppSync Merged APIs were
   literally built to provide; matches Reventless's plugin model exactly.
5. **Standalone services fall out for free** — a source API, no registration protocol.
6. **Resolver/schema ordering becomes intra-stack** — no cross-stack `schemaPushed` gate.
7. **Built-in subscriptions, auth-mode merging, observability, custom domain, WAF, caching** on the
   merged API — no bespoke handling.

## 7. Cons / risks / consequences

1. **Large blast radius; supersedes now-shipped work.** This is a different architecture, not an
   increment. It would retire `GraphQL_Stitcher`'s push role, `Api_Adapter.updateSchema`, the
   ApiFragmentRegistry aggregate, the reactive push, and the deploy caller/waiter — **all of which
   are now built, landed, and deploy-validated** (the plan completed 2026-07-14; the header note).
   Adopting merged APIs means *deleting* that shipped machinery, not avoiding building it — the
   "build-then-delete" concern from the original draft is resolved: the push path exists and works,
   so this is a clean successor migration off a known-good baseline rather than a mid-flight pivot.
2. **New Pulumi bindings + resource model** (`SourceApiAssociation`, merged API) — net-new binding
   and deploy-topology work, plus the per-plugin-owns-an-API restructuring of plugin stacks.
3. **Shared-type discipline is now load-bearing** — codegen must emit shared types canonically and
   `@hidden`/stub them elsewhere, or every mismatched field silently becomes a `MERGE_FAILED`. The
   stitcher's forgiving dedupe is replaced by AWS's strict merge.
4. **Subscription fan-in colocation constraint** — a real expressiveness limit; needs an audit and
   possibly a schema restructuring for any cross-plugin subscription.
5. **Source-API ceiling (default 10 per Merged API)** — a scaling limit with no analog today. Under
   the naïve 1-plugin = 1-source-API mapping this caps plugins-per-platform, but it is a **soft,
   adjustable service quota**, not a hard wall: AWS quota `Source API associations per Merged API`
   (code `L-3B7F188C`), default 10, **Adjustable: Yes**
   ([AWS General Reference — AppSync quotas](https://docs.aws.amazon.com/general/latest/gr/appsync.html);
   increase via [Service Quotas](https://console.aws.amazon.com/servicequotas/home/services/appsync/quotas/L-3B7F188C)).
   Mitigations: (a) request a quota increase — the primary lever; (b) a bounded-plugins-per-merged-API
   design that groups several plugins behind one source API so the ceiling counts *source APIs*, not
   *plugins* — at the cost of some plugin-deploy isolation (grouped plugins share a source API and lose
   independent-deploy granularity). Because the quota is adjustable, there is **no hard N-plugin
   platform limit**; grouping is only the fallback if you outgrow the granted ceiling.
6. **Async merge failure surface** — a new waiter/health model on association status; and a source
   API whose merge fails is live-but-unmerged (its fields silently absent from the endpoint until
   fixed).
7. **Coarse non-top-level auth** on the merged endpoint — a behavioral change to validate.
8. **Two divergent local options** — either accept a fidelity gap (option a) or take on the scope-2
   local refactor (option b) to mirror AWS.
9. **UI fragments are unaffected** — the `UiFragmentRegistry` is runtime-connect-driven and is *not*
   a schema push (it feeds the host-shell manifest), so none of this simplifies it; it stays as-is.

## 8. Impact on the (now-shipped) plan

The referenced plan is **complete** (all four phases deploy-validated on alpha, 2026-07-14). So this
section reads as "what a merged-API migration would *undo*," not "what it would pre-empt."

**Superseded (API side) if adopted:** the ApiFragmentRegistry component (the singleton aggregate that
shipped), the reactive single-writer (mjs/SideEffect), the deploy caller + `Platform_ApiFragments`
status query + waiter, the singleton-aggregate consistency reasoning, and `Api_Adapter.updateSchema` /
the runtime re-stitcher as the push path. The `deploy-schema:*` keyspace and its guards — already
**deleted** as part of the Phase-4 cutover (commit `549afe73c`) — do not return under merge.

**Still needed / still useful:** neutral-SDL emission + dialect-additive providers (increment 2a) —
each source API's schema should still be neutral SDL that the AWS side decorates and the local side
composes. The **bootstrap** changes character: the admin base becomes a *source API* (canonical owner
of shared types + the `Platform_*` fields) rather than a whole-replace seed. The **UI fragment
registry** is orthogonal and remains.

**Net:** merged composition is arguably the *correct long-term shape* — it makes the coordination
problem, the retirement gap, and the push race all non-existent rather than managed — but it is a
larger re-architecture than the current plan and lands mostly on the AWS resource/binding layer, with
a strict shared-type/subscription contract as the main design risk.

## 9. Fragment registry under merged composition — aggregate, DCB, or neither?

The question the merge model forces: if the whole-replace push disappears, what happens to the
`ApiFragmentRegistry` the now-shipped plan built — does it become an aggregate, DCB slices, or
nothing?

**It is retired on the API side, not re-answered.** The registry exists to hold two things, and
merged composition removes both:

1. **Cumulative stitched-schema state** (fragment-per-plugin, folded into one artifact). Under
   merge this lives in AWS as `SourceApiAssociation` records — the platform *composes* source APIs,
   it does not store-and-stitch a shared artifact. There is no cumulative document for a Reventless
   component to own.
2. **Push coordination** (single-writer automation, the `RegisterApiFragment` /
   `RecordApiFragmentPush` command surface, the `Platform_ApiFragments` status query, the deploy
   waiter). All of it is a consequence of many writers hitting one schema; with per-plugin source
   APIs there is exactly one writer per API and nothing to serialize.

So the aggregate-vs-DCB decision the plan defers to `aggregate-vs-dcb-decision-guide.md` is
**moot** — there is no per-plugin schema-composition state left for an event-sourced component to
model. § 8 already lists the `ApiFragmentRegistry` ("aggregate or slice") under *Superseded (API
side)*; this section is the explicit answer to "then which is it?": **neither.**

**If a thin registry is nonetheless kept**, two residual motives exist, and for both the shape is
**DCB slices — not an aggregate — as a passive ledger, never a writer:**

- **Discovery / audit** — which plugins are sources of which merged API, at what version. State is
  per-plugin-name with no cross-entity consistency need, and `@@reventless.systemCallable` is
  defined on slices, so the same reasoning that chose DCB slices in the current plan holds. But it
  records association facts; it does not drive a push.
- **Merge-health surfacing** — projecting `MERGE_FAILED` detail into a platform read model. Again a
  passive projection, DCB-slice territory.

Neither is load-bearing: AWS is the source of truth for both, queryable via
`GetSourceApiAssociation`. **Default recommendation: nothing survives on the API side.**

**Unaffected by the pivot:**

| Component | Under merged APIs |
|---|---|
| **ApiFragmentRegistry** (API schema) | **Deleted** — state moves into AppSync's merge; no aggregate, no slice (optional thin DCB *ledger* only) |
| **UiFragmentRegistry** (host-shell manifest) | **Unchanged** — runtime-connect-driven, *not* a schema push (§ 7, con 9); the shipped Phase-1 admin DCB slices stay correct |
| **Plugin aggregate** | **Unchanged** — lifecycle only (Connected / VersionSuperseded / Retired); already stripped of fragment payloads |

## 10. Anatomy of a single-plugin schema update

"Push-free" does not mean "call-free." A plugin schema change still calls AppSync — what changes is
*which API it targets*: the plugin's **own** source API (single-owner), not one shared Domain API
(many writers). That single retarget is what deletes the lease / hash / stitch / drift-repair /
shrink-guard machinery.

**Today (for contrast):** the plugin computes a *fragment* (its fields only), SigV4-calls
`Platform_RegisterApiFragment`, and a single writer re-stitches *all* fragments + admin base and
whole-replace-pushes the result to the one shared Domain API (`Platform.res:742-757`;
`startSchemaCreationRetrying` → `waitForSchemaActive`). The plugin's deploy then polls push status
before creating resolvers. Every guard exists because that shared push has many writers.

**Under merged APIs**, a plugin owns its own source API (a normal `AppSync::GraphQLApi` in the
plugin's own stack). A schema change is entirely intra-stack until the final merge:

1. **Recompute the plugin's own SDL** — its own types/fields only, *no stitch* with other plugins or
   the admin base.
2. **Update the plugin's source-API schema.** *This is where the AppSync call lives.* It is the same
   primitive the bootstrap already uses — `StartSchemaCreation` + poll `GetSchemaCreationStatus` to
   `ACTIVE` — but aimed at the **plugin's own API**. Because there is exactly one writer per source
   API (the plugin's single Pulumi process), this becomes a **declarative Pulumi resource** —
   `aws.appsync.GraphQLSchema(apiId=pluginSourceApi, definition=pluginSDL)` — and Pulumi's own
   CREATE/UPDATE performs the `StartSchemaCreation` + status-poll internally. No lease, no hash, no
   stitch, no shrink guard, because nothing else writes this API.
   - *This reverses the plan's "Bootstrap-push decision".* That decision rejected a declarative
     `GraphQLSchema` resource because the Platform API is cumulative and would drift against plugins'
     pushes. Merged APIs remove the cumulative-ness — each source API is single-owner — so the
     declarative resource becomes viable again. The rejection was a symptom of the shared-artifact
     model.
3. **Create/update the plugin's resolvers** against its own source API — same stack, so the
   schema→resolver ordering (the `schemaPushed` Output gate, `Plugin_Builder.res:585`) becomes an
   ordinary intra-stack resource dependency, not a cross-stack SigV4-poll gate.
4. **Propagate to the merged endpoint**, governed by the `SourceApiAssociation`'s `mergeType`:
   - **`AUTO_MERGE`** — AWS re-merges automatically on the source-API change; *no explicit call*, and
     the platform's merged API is never re-pushed.
   - **`MANUAL_MERGE`** — one call: `StartSchemaMerge(associationId)`.

**So the "call to AppSync" is:** *always* step 2 (the plugin's own `GraphQLSchema`); *maybe* step 4
(`StartSchemaMerge`, only under manual merge); and *optionally* a status poll —
`GetSourceApiAssociation` for `MERGED` vs `MERGE_FAILED`. That poll is the one genuinely new
mechanism (§ 4, risk 5): auto-merge is async and Pulumi will not necessarily block on the re-merge,
so a deploy that wants to *fail loudly* on an incompatible change polls association status here. It
queries **AWS's own resource state**, replacing today's poll of the custom `Platform_ApiFragments`
push status.

**Failure model.** Blast radius shrinks to the plugin: an incompatible shared-type change flips
**only that plugin's association** to `MERGE_FAILED` (its fields silently drop from the merged
endpoint until fixed); every other plugin is untouched. Today the same mistake threatens the one
shared artifact (hence the shrink guard + drift repair).

**One-time setup (not per-update):** the merged API's `mergedApiExecutionRole` needs
`appsync:SourceGraphQL` on each source API, and each source API's primary auth mode must be the
merged API's primary-or-secondary. Association-creation-time; it does not recur per schema change.

**Local (yoga):** no AppSync call at all — a plugin schema update is the in-process `rebuildSchema`
(already push-free); option (b) re-runs `mergeSchemas` over the changed subschema. The "there must
be a call somewhere" concern is AWS-only.

## 11. Sketch — plugin-stack Pulumi resource graph + net-new bindings

**Per-plugin stack** (every domain/platform plugin, and every standalone service, deploys this
shape):

```
Plugin stack
├── aws.appsync.GraphQLApi              (pluginSourceApi)   apiType = GRAPHQL
│      auth: plugin's primary mode (must be the merged API's primary or a secondary)
├── aws.appsync.GraphQLSchema           (definition = plugin's own neutral SDL + AWS dialect)
│      └─ depends on pluginSourceApi
├── aws.appsync.DataSource   × N        (DynamoDB / Lambda, as today)
├── aws.appsync.Function     × N        (as today)
├── aws.appsync.Resolver     × N        (bound to pluginSourceApi; depends on GraphQLSchema)  ← intra-stack schema→resolver gate
└── aws.appsync.SourceApiAssociation    (mergeType = AUTO_MERGE)
       mergedApiIdentifier = <platform merged API ARN, from platform StackReference>
       sourceApiIdentifier = pluginSourceApi.arn
       └─ depends on GraphQLSchema + all Resolvers   ← merge only after the source API is complete
```

**Platform stack** (owns the merged API + admin, once):

```
Platform stack
├── aws.appsync.GraphQLApi   (domainMergedApi)     apiType = MERGED, mergedApiExecutionRole
├── aws.appsync.GraphQLApi   (platformMergedApi)   apiType = MERGED   (split mode only)
├── admin source API         = aws.appsync.GraphQLApi + GraphQLSchema + Resolvers   (§ 12)
│      canonical owner of shared types + Platform_* fields
└── aws.appsync.SourceApiAssociation  (admin source → platform merged API)
```

Cross-stack wiring is a **StackReference** carrying the merged API ARN(s) into each plugin stack —
replacing the SigV4 `RegisterApiFragment` mutation and the deploy waiter entirely. The
`apiTarget = Domain | Platform` dimension collapses to *which merged API ARN the association points
at*.

**Net-new `rescript-pulumi-aws` bindings** (grep-confirmed absent — § 4, risk 1). Existing today:
`GraphQLApi`, `DataSource`, `Resolver`, `Function`.

| Binding | Purpose | Notes |
|---|---|---|
| `GraphQLApi.apiType` (`GRAPHQL` \| `MERGED`) + `mergedApiExecutionRole` | mark an API as a merged API | extend the existing `GraphQLApi` binding, not a new resource |
| `aws.appsync.GraphQLSchema` | **declarative** schema resource (replaces imperative `StartSchemaCreation`) | the single biggest simplification; makes a per-source-API schema an ordinary Pulumi resource |
| `aws.appsync.SourceApiAssociation` | link source API → merged API | `mergeType`, `mergedApiIdentifier`, `sourceApiIdentifier`; the core new resource |
| (optional) `GetSourceApiAssociation` read / poll helper | surface `MERGE_FAILED` in deploy output | only if failing-loud on async merge is wanted; mirrors today's status poll |

The `aws-native` provider already exposes `AWS::AppSync::SourceApiAssociation` (Cloud Control) as an
alternative to hand-writing the classic binding — consistent with the repo already using
`aws-native:appsync:Resolver` on the admin path.

**What leaves the plugin stack:** the fragment computation, the SigV4 caller
(`registerFragmentViaApi`), the `ApiFragmentDeregistration` dynamic provider, and the push waiter —
all replaced by the two declarative resources above.

## 12. Sketch — admin base as a canonical source API (shared-type contract + Relay `node`)

Under merge, the admin base stops being a whole-replace *seed* and becomes an ordinary **source
API** — but a privileged one: the **canonical owner of every shared type**. This is where the merge
model's strict shared-type discipline (§ 4, risks 2–3; § 7, con 3) is discharged.

**Shared-type ownership contract.** The admin source API defines, `@canonical`, the types every
plugin references:

```graphql
# admin source API schema (canonical owner)
type PageInfo @canonical { hasNextPage: Boolean! ... }          # Relay
interface Node @canonical { id: ID! }                            # Relay
union CommandResult @canonical = CommandAccepted | CommandRejected | CommandPending
type CommandAccepted @canonical { ... }
type CommandRejected @canonical { ... }
type CommandPending  @canonical { ... }
# + Platform_* mutations/queries + Plugins RM + Relay connection base types
```

Every other source API that needs one of these either **defines it identically** (union-of-identical-
fields merges cleanly) or references it and marks its own copy `@hidden`. The rule the codegen must
enforce: **emit shared types canonically from the admin source; `@hidden`/stub them everywhere
else.** A single divergent field type flips that association to `MERGE_FAILED`. This replaces
`GraphQL_Stitcher`'s forgiving leading-name dedupe (`GraphQL_Stitcher.res:164-172`) and the
once-only `stampSharedIamTypes` with AWS's strict merge + a codegen discipline. Concretely, the
emission that today stamps the `CommandResult` family into *every* mutation-bearing fragment
(`GraphQL_FragmentGenerator.res:13-28`) must instead emit it **once** (admin, `@canonical`) and
reference-only elsewhere.

**The Relay `node` blocker — decision required up front (§ 4, risk 3).** The stitcher injects one
global `node(id: ID!): Node` and every plugin registers its return types into that single resolver's
registry (`QueryDbResolvers_AppSync.registerNodeType`). AppSync Merged APIs **forbid two source
resolvers on one field**, so `node` cannot be co-resolved across source APIs. Three options, all with
cost:

| Option | Mechanism | Cost |
|---|---|---|
| **(a) Drop global `node`** | remove the field; rely on per-type root queries | Relay-compliance regression; UI/traversal code calling `node(id:)` breaks |
| **(b) Admin owns `node`** | one resolver in the admin source API with a data source per plugin | breaks plugin isolation — the exact property the split buys; admin gains a dependency on every plugin's store |
| **(c) `node` as field-resolver indirection** | thin admin `node` returns a typed stub; the concrete type's fields resolve via the owning source (AppSync "field-resolver pattern") | most faithful, most work; needs a per-type dispatch convention encoded in codegen |

Recommendation for the spike: prototype **(c)**; fall back to **(a)** if the field-resolver pattern
proves too heavy — do *not* take **(b)**, which negates the isolation the whole architecture is for.
This is the single most concrete thing merge breaks and should gate the go/no-go decision.

**Subscription colocation (§ 4, risk 4).** The admin base's `onUIFragmentChange ← 3 mutations` fan-in
(`AdminApi.res:92-99`) is safe *because those mutations live in the admin source API*. The general
rule the codegen must uphold: a subscription and every mutation its `@aws_subscribe` fans in from must
live in the **same source API**. Per-plugin "Source-C" subscriptions
(`Plugin_SubscriptionSchema.res:27-55`) are safe by construction; any cross-plugin fan-in is not
expressible and needs a schema restructuring. An audit of every `@aws_subscribe` producer is a
precondition.

## 13. Verdict & recommendation

**Feasible on both platforms.** Local is nearly free (already an in-process merge; option (b) buys
parity with a contained refactor). AWS is feasible with **four concrete gating risks**: (a) new
Pulumi bindings for `SourceApiAssociation`/merged APIs; (b) canonical shared-type ownership enforced
by codegen; (c) subscription fan-in colocation (audit `@aws_subscribe` producers); (d) the 10-source
ceiling + async-merge failure model. None is a blocker; together they are a real project.

Suggested path if pursued:

1. **Prototype spike on AWS** — an admin source API + two domain plugin source APIs merged into one
   Domain merged API — to validate the three behaviors the docs leave least certain for *this*
   codebase: shared-type merge (Relay + IAM types via `@canonical`/stub), per-plugin Source-C
   subscription merge, and Cognito+IAM dual-auth via merged secondary auth mode.
2. **Sequencing is already decided by events.** The original draft weighed (i) landing
   `event-sourced-fragment-registries.md` first vs (ii) pivoting before Phase 4 to skip building the
   reactive-push/deploy-waiter machinery. Outcome (i) happened — the plan **landed and deploy-validated
   on 2026-07-14** — so option (ii) is moot. The live question is now purely *whether and when to
   migrate off* the shipped push path to merged APIs; the spike's outcome should drive that, with no
   time pressure since the current path works.
3. **Do local option (b) alongside scope-2** so both platforms share the plugin=subgraph model rather
   than diverging.

**Non-goal to keep in view:** this does not touch the UI fragment registry, which is not a schema
push.
