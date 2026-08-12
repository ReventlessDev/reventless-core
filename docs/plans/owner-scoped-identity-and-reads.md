# Plan: a row can belong to the caller, and the framework enforces it

**Status.** §10 steps 1–6 landed 2026-08-12 — all four read paths and the write
path enforce `@owner`, and a deployment that forgets to name its operator groups
is now told so per view instead of silently scoping its administrators. Steps 7–8
open. ⚠️ **No deployment has set `elevatedGroups` yet**, which is correct today
(no component declares `@owner` outside tests) and becomes required the moment
one does. Planned 2026-08-12 after a code survey of the write path, the four read
paths, and both identity transports.

**Goal.** A generated surface can state which field ties a row or a command to
the caller who made it, and the framework then (a) stamps that field from the
authenticated identity rather than trusting the client, and (b) narrows reads of
that view to the caller's own rows. One annotation, enforced server-side, on
every transport.

**Non-goal.** A general attribute-based access-control language. The predicate
this lands is deliberately one shape — *this field equals this caller* — because
that is the shape the resolver can push into storage. Anything richer belongs in
the ABAC package, and §8 says what this plan must not foreclose for it.

---

## §1 — What is missing, precisely

The framework already carries a per-request `Identity.t`
(`reventless/spec/src/types/Identity.res`) from both transports into both the
write and read paths. It is used for exactly one thing: evaluating an
`Authorization.permission` — an all-or-nothing verdict per component
(`reventless/spec/src/types/Authorization.res`, `isAllowed`).

There is no vocabulary between "everyone in the group may read this view" and
"nobody may". So:

- **A view is either wholly readable or wholly refused.** A caller allowed to
  read a view reads *every row in it*, including rows describing other people.
  This is the default state of every generated read model and state-view slice
  the framework produces.
- **A command's caller-identifying field is a free-typed payload string.** The
  write path builds the command JSON from `payload.arguments` verbatim
  (`reventless/core/src/components/CommandGenerator/CommandGenerator_Callback.res:54-74`)
  while `payload.identity` sits unread beside it, consulted only by the optional
  user interceptor at `:124`. A client may therefore claim to be anyone in any
  field the schema declares.

The two halves are one gap. Stamping without scoped reads means rows are labelled
correctly and readable by everyone; scoped reads without stamping means the label
is whatever the client typed. Neither half is worth shipping alone, which is why
this is one plan.

## §2 — One annotation, one carrier

`@owner`, on a field, in both the `@schema type state` record of a queryable and
the payload of a `@schema type command` variant.

**Carry it as sury field metadata, the way `@ref` is carried** — not as a new
entry in `StateAnnotations.stateAnnotationSpec`. The tempting precedent is
`@status` / `@groupBy` (`reventless/spec/src/components/StateAnnotations.res:67-82`):
single-field, PPX-emitted, duplicate-detected. It is the wrong precedent, for a
structural reason: `stateAnnotationSpec` is attached to a **state record**, and
half of this annotation's job is on **command variants**, which have no state
record. `@ref` already solved exactly this — `Reference.getFieldTarget` reads a
marker off the field schema, and `Plugin_Structure.extractReferences` (`:173-186`)
runs the *same walk* over command properties and event properties because "the two
ask the identical question of identical field dicts". `@owner` asks that question
in three places. Give it one answer.

Concretely:

- `reventless/spec/src/components/Owner.res` (new) — a metadata id, an
  `Owner.string` schema constructor, and `getFieldOwner: S.t<unknown> => bool`,
  mirroring `Reference.res:27-76`. **Reuse `getFieldTarget`'s walk, including its
  reasoning** (`Reference.res:49-65`): the marker on an `array<string>` field sits
  on the element schema, so a reader asking the field's own schema gets `None`
  and concludes "no owner declared" — which for an access-control predicate means
  silently unscoped. Follow optionals and array elements; do not follow object
  properties.
- `SuryToJsonSchema.deriveObjectSchema` — emit `x-reventless-owner: true` on the
  named field. This is what reaches a client: command payload schemas already
  travel through `deriveObjectSchema` (`Plugin_Structure.res:368-372`, added
  precisely so a command's field markers reach the wire), so the shell gets this
  for free on the write side.
- `packages/reventless-ppx/src/ppx/StateAnnotations.ml` — the `@owner` shorthand.

**The PPX is the last step, not the first.** `@ref` is sugar over
`@s.matches(Reference.to_(…))` (`Reference.res:16`), and `@owner` is the same
shape — so the whole enforcement chain can be built, tested and shipped against a
hand-written `@s.matches(Owner.string)`, with the OCaml attribute added
afterwards as pure ergonomics. That ordering keeps the security work off the
critical path of a compiler-plugin change, and it means the annotation's *reader*
is proven before its *writer* exists.

When the shorthand does land it must error on **more than one `@owner` per record
or variant**: two owners is not a richer rule, it is an unanswered question about
which one the read predicate uses. Until then that check lives in the structure
walk, which is where the ambiguity would actually bite.

## §3 — Stamping happens in `makeGenerateCommand`, not in the interceptor

The orchestrating analysis nominated `CommandGenerator_Callback`'s interceptor
hook as the seam. The survey says otherwise, on two counts.

**The interceptor cannot do it.** `commandInterceptor` returns
`interceptResult = Allow | Deny(string)` (`CommandGenerator_Callback.res:1-8`).
It is a veto, not a rewrite. Teaching it to return replacement arguments turns a
yes/no hook into a mutation hook and hands application code the ability to
rewrite any command en route — a much larger authority than the one feature
needs.

**The interceptor is the wrong layer anyway.** It is a *user extension* point,
filled by an application's `RuntimeExtension`. Stamping an owner is framework
behaviour derived from a framework annotation; it must hold whether or not an
application registered anything.

**The right seam is `makeGenerateCommand` itself** — and choosing it is what buys
transport symmetry rather than promising it. The local GraphQL resolver builds
`payload` with `identity` at
`reventless/local/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res:202-212`
(and again at `:265-275` for DCB); the AppSync path builds the identical payload
in generated JS
(`rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res:866-901` for
aggregates, `:904-941` for DCB) and hands it to
`CommandGeneratorEntryPoint_Ops.makeCommandGenerator`, which calls the same core
function. Stamping in either resolver would need mirroring in the other and would
silently drift; stamping in `makeGenerateCommand` is written once and is true on
both. The transport-drift failure mode this repo has paid for before is avoided
by construction, not by discipline.

The stamp goes in the `params` construction (`:54-70`), after the id strip and
before `commandJson` is assembled at `:72-77`: for each property of the resolved
variant schema
carrying `@owner`, **overwrite** the value with the caller's id. Overwrite, not
fill-if-absent — an absent field and a forged field must produce the same row, or
the rule is advisory.

## §4 — Who is exempt is deployment configuration, and the IAM caller has no identity at all

Two callers must not be stamped or scoped: an operator reading across everyone,
and the platform's own service-to-service traffic. Both need naming, and neither
belongs in a schema annotation.

**Elevation is one list, platform-wide.** Not a parameter of `@owner`
(`@owner(elevated=["Admin"])`), because the moment it is per-annotation, two
views disagree about who an operator is and the shopper who is scoped on one view
is unscoped on the next. "Who administers this deployment" is a deployment fact.
It belongs beside the auth adapter configuration, as a single
`ownerScopeElevatedGroups: array<string>`, defaulting to `[]` — an empty default
being the safe one, since it scopes everybody.

**The IAM caller is the sharp edge, and it is already visible in the generated
code.** E6(b) recorded that every `eu-west-1` AppSync API carries `AWS_IAM` as an
additional provider. The resolver templates show what that produces: the
non-Cognito branch emits `{ userArn, accountId, username, provider: 'IAM' }`
(`AppSync_Resolver_Functions.res:888-895`) — **no `userId` and no `groups`**,
though `Identity.t` declares both as non-optional. So a naive implementation does
the worst possible thing twice over: the group check finds no `groups` and
concludes "not elevated", then the stamp writes `undefined` into the owner field.
Every service-written row lands owned by nobody, readable by nobody, and the
failure is silent.

Therefore the elevation test is *not* `groups ∩ elevatedGroups ≠ ∅`. It is:

1. `provider` is not a Cognito/InMemory user identity → **elevated** (system
   caller; no stamping, no read scoping).
2. `userId` is absent or `"anonymous"` (`Identity.res:22-27`) → **refuse the
   write**, rather than stamp a sentinel. A command that must record an owner and
   has no identity to record is not a command that should succeed.
3. otherwise → elevated iff `groups` intersects `ownerScopeElevatedGroups`.

Rule 1 is a real widening of trust and must be written as such: it says an
IAM-signed caller is inside the trust boundary. That is already true of every
resolver in the estate — the IAM provider exists for the platform's own Lambdas —
but this plan is the first to *depend* on it, so it is stated here rather than
assumed.

## §5 — The read predicate must not travel through the public filter

The obvious implementation is to inject `filter.customerIdEq = <caller>` into the
arguments and let the existing machinery do the work. It is wrong twice.

**The filter surface may not contain the field.** The client-visible filter is
derived from `deriveServerCapability`
(`reventless/core/src/components/Api/GraphQL_FragmentGenerator.res:271-330`),
which admits only fields carrying `@id` / `@compositeId` / `@subId` / `@index` /
`@scan` / `@scanSort`, plus the resolved key field. An owner field with none of
those annotations — the normal case — is simply not filterable, so the injection
has nowhere to land. Requiring authors to also write `@scan` would make the
security of the view depend on a performance annotation, which is the wrong
dependency in the wrong direction.

**A client-supplied channel is a client-controllable channel.** Even where the
field is filterable, the caller's own `filter` argument arrives in the same dict.
Scoping must compose with the client's filter as an unconditional AND that the
client cannot address, name, or overwrite.

So: a **separate `~ownerScope: option<(string, string)>` argument** — field name
and required value — threaded alongside the `~capability` and `~labelField`
arguments the read paths already carry, resolved from the identity at the top of
each resolver and never read from `args`.

It must be applied **before pagination**, not after. Filtering a materialised
page post-hoc produces short pages and wrong cursors, and the bug reads as "the
list sometimes ends early" rather than as an access-control fault.

## §6 — Four read sites, and the DynamoDB one is the real work

`@owner` scoping has to land at every place a list is served, or a shopper is
scoped on sqlite and not in production.

1. **Shared spec —** `QueryDbListQuery.run`
   (`reventless/core/src/components/Api/QueryDbListQuery.res:78-84`) gains
   `~ownerScope` and applies it as one more entry in its `perFieldChecks` chain,
   ahead of the search/ids block. This one change covers the local in-memory
   fallback *and* the Postgres fallback
   (`reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res:258-272`),
   because both delegate to it when their push-down declines.
2. **SQLite push-down —** `QueryDbStorage_Sqlite.listPage` (`:425-518`) must take
   the predicate into its generated `json_extract` WHERE clause. If it is only
   applied in the fallback, the push-down path — the normal path — returns
   everything.
3. **Postgres push-down —** the same, in `pushdowns.listPage`
   (`PgQueryResolver_Lambda.res:65-70`).
4. **DynamoDB via AppSync —** `Resolver.Functions.listAllItemsConnection`
   (`QueryDbResolvers_AppSync.res:242-252`) is generated JS running *in AppSync*,
   with no Lambda in the path. The predicate has to be baked into the emitted
   code as a `FilterExpression` term reading `ctx.identity`, with the elevation
   test emitted alongside it. There is precedent for exactly this shape:
   `authorizeIndexedAccess` (`AppSync_Resolver_Functions.res:971-988`) already
   reads `ctx.identity.claims['cognito:groups']` and branches on membership
   inside a generated resolver.

   ⚠️ **A DynamoDB `FilterExpression` is applied after the page is read**, so a
   scoped list over a large table returns short pages with a valid `nextToken` —
   correct, but pathological when a caller owns a small fraction of the rows.
   The durable answer is a GSI on the owner field. This plan should emit a
   deploy-time warning when an `@owner` field is not the partition key of any
   index on the table — mirroring the existing `validateScanSortAlignment`
   warning (`QueryDbResolvers_AppSync.res:220-231`), which was added for the same
   class of "works, but scans" mistake. Auto-provisioning the index is a
   reasonable follow-up and is deliberately not in this plan.

The single-item doors (`getById`, `XsByIds`) need the check too, but there it is
a post-read comparison rather than a pushed predicate — cheap, and the same
branch `authorizeIndexedAccess` already takes in its `response`.

## §7 — What the manifest publishes

`queryableDef` gains `ownerField: option<string>` beside `statusField`
(`reventless/spec/src/components/Plugin.res:260`), and `commandDef` gains the
same beside `requiredAccess` (`:209`). Both are derived at structure-build time
from the field metadata — no second authoring step, the same discipline the
`requiredAccess` derivation settled on.

This is what lets a shell drop an owner field from a generated form (the server
is going to overwrite it) and drop the owner column from a scoped list (it is
constant). Note the client cannot *derive* either fact: it does not know whether
the caller is elevated in the framework's sense, and it must not guess — the
manifest states the annotation, the client asks its own identity, and the two
answer independently. The shell-side work is a separate plan in the UI repo.

**The baked manifest inherits this for free**, as `requiredAccess` did, provided
the curation step copies the new fields — worth an explicit check, since a
storefront serving a baked manifest is exactly the deployment where owner scoping
matters most.

## §8 — What this does not do

**It is not ABAC.** One field, one equality, one caller. Ownership by team,
delegation, "my department's orders", and time-boxed grants are all outside it.
The annotation is designed to survive that migration as a *source* rather than a
mechanism: when the ABAC package lands, `@owner` becomes one policy generator
among several and the resolver-level predicate becomes one evaluator. Nothing
here should encode the predicate anywhere an ABAC evaluator could not later
replace it — in particular, the generated AppSync code must be produced from the
same resolved `ownerScope` value the other three sites take, not hand-written per
resolver.

**It does not make a denied read distinguishable from an empty one.** That defect
is already filed (`docs/plans/Backlog/denied-query-returns-empty.md`) and this
plan makes it worse in one specific way: after owner scoping, an empty result is
*also* the correct answer for a caller who owns nothing. Fixing the refusal path
does not fix this — a scoped read is an allowed read that legitimately returns
zero rows. The consequence is for testing, and §9 handles it there.

**It does not scope subscriptions or the event history.** A live-updates channel
on an owner-scoped view will still push other people's rows. Naming it here so
that it is a known gap rather than a discovery: the `@live` seam and
`EventHistoryResolvers` take no `ownerScope` in this plan.

## §9 — Acceptance, and why it must be positive-controlled

Because empty is a legitimate answer, "the shopper's list is empty" proves
nothing — a completely broken predicate produces it, and so does a correct one.
Every acceptance step below is therefore stated as a **non-empty** assertion with
a known expected count.

Seed two owners, A and B, with a known, different, non-zero number of rows each,
plus at least one row owned by neither.

- **Read scoping.** A's token lists exactly A's rows: count matches, every row's
  owner field is A, and the count is strictly less than the total. B's token
  likewise. An elevated token sees all rows including the third-party ones.
- **Pagination.** With `first` set below A's row count, paging through to the end
  yields exactly A's rows and no duplicates — the check that catches a predicate
  applied after the page rather than inside it.
- **Stamping, absent field.** A calls the command omitting the owner field
  entirely; the resulting row is owned by A.
- **Stamping, forged field.** A calls the same command passing B's id in the owner
  field; the resulting row is owned by **A**. This is the single most important
  assertion in the plan, and it is the one an implementation that fills-if-absent
  fails.
- **System caller.** A row written by an IAM-signed internal caller succeeds and
  is not owned by `undefined`.
- **Both transports.** The whole list runs locally and against a deployed stack.
  Local-only evidence does not establish the AppSync-generated path, which shares
  no code with the other three.

## §10 — Order of work

1. ✅ **Done 2026-08-12.** `Owner.res` + `deriveObjectSchema` marker, driven by
   `@s.matches(Owner.string)`. `owners` is threaded into
   `objectRefToJsonSchema` the way `optional` already is — a list of field names
   the caller reads off the sury schema — rather than as a case in `SchemaType`,
   because the IR is shape-driven and ownership does not change a field's shape.
   Four tests in `SuryToJsonSchemaTest`, of which two are the ones that matter:
   an unmarked sibling field stays bare (a bug marking everything would otherwise
   pass), and an **optional** owner field is still recognised — the wrapper case
   that fails open.
2. ✅ **Done 2026-08-12.** `Reventless.OwnerScope` — `resolve` classifies a caller
   as `System` / `Elevated` / `Owned` / `Unidentified`, with `elevatedGroups` as a
   deployment-wide ref defaulting to empty. 19 tests.

   Two findings while building it, both recorded in the module:
   - **The runtime shape is worse than §4 said.** `Cognito` and `InMemory` compile
     to bare strings while `Custom(_)` compiles to an object, so a modelled
     provider is told from an unmodelled one by `typeof`. And the identity can be
     absent *in its entirety* — an internal caller that assembles a payload
     without one arrives as `undefined`, where reading a field raises a TypeError
     and surfaces as a crash rather than as the refusal it is. Every field read in
     the module goes through a nullable cast for that reason.
   - **`systemProviders` is an allowlist, and the direction is the safety
     property.** "Anything not modelled is a system caller" would hand unscoped
     reads to whoever adds the next provider. Unrecognised now lands in
     `Unidentified` and is refused. There is a test for exactly that, because it
     is the branch that fails silently in the wrong direction.
3. ✅ **Done 2026-08-12.** `stampOwnerFields` in `makeGenerateCommand`, resolving
   the marked fields of the *issued variant* via `Owner.variantFieldNames` so the
   stamp cannot reach across constructors of one command union. 9 tests driven
   through `makeGenerateCommand` rather than by calling the stamp directly —
   the claim worth testing is that the stamp is reached on the path a command
   actually takes, which a direct call cannot establish.

   The refusal is scoped to commands that **carry** an owner: an anonymous caller
   invoking an unowned `AllowAnonymous` command has nothing to prove, and refusing
   it there would silently narrow that rule. Exempt callers keep the value they
   sent, so acting on another principal's behalf stays possible for those who may.
4. ✅ **Done 2026-08-12.** `~ownerScope` through `QueryDbListQuery.run` and both
   SQL push-downs (`QueryDbStorage_Sqlite.listPage`,
   `QueryEnginePostgres.listPage` / `itemsPage`), plus every door on both
   dispatchers — not just the connection list. Six on the local resolver
   (`getById`, `byIds`, connection, legacy list, sub-id `Items`, by-index) and
   five on the Postgres Lambda. A scoped list beside an unscoped `XsByIds` is a
   hole, not a partial delivery.

   `OwnerScope.decide` / `scopeOf` were added so the four read paths share one
   answer rather than four copies of the same `switch` — the copies would each
   have been free to decide that an unidentified caller "just sees nothing".

   Two properties the tests pin, beyond "it filters":
   - **Parity.** The push-down and the shared spec are asserted equal under a
     scope, including scope-composed-with-a-client-filter. The push-down is what
     a deployment runs; the spec is what tests reach most easily. A predicate in
     only one of them passes every fallback-based test.
   - **Pagination.** `first: 2` against an owner holding 3 of 5 rows returns two
     *owned* rows. A LIMIT taken before the narrowing returns one, and that bug
     reads as "the list sometimes ends early".

   ⚠️ **The Postgres SQL is compiled but not executed by any test.** Its parity
   harness is `PG_URL`-gated and does not run by default, so the Postgres arm of
   this step rests on review and on its structural symmetry with the SQLite arm.
   Run the gated harness against a real Postgres before treating that path as
   verified.
5. ✅ **Done 2026-08-12.** `listAllItemsConnection` takes `~ownerField` /
   `~elevatedGroups` and emits the predicate into the resolver source, ANDed with
   whatever the client filtered on. `QueryDbResolvers_AppSync` derives the field
   from the same schema `capability` comes from, and warns at deploy time when
   that field is not the key of any index on the table — the FilterExpression is
   applied after the page is read, so pages shrink as a caller's share of the
   rows falls. Warned rather than refused: the query is served correctly, and a
   small table may reasonably accept the cost.

   The branch order is load-bearing and is the mirror of §4: `sub == null` is
   tested **before** group membership, because an IAM service caller has no `sub`
   for a reason unrelated to being anonymous. Reversed, it reads as
   non-elevated and then filters on `undefined`, and every service read returns
   nothing.

   Eight tests, and they **evaluate the emitted JavaScript** rather than matching
   its text (`rescript/pulumi-aws/tests/` already had a harness that does this).
   That is the strongest check available without a deployed stack — it is what
   catches an APPSYNC_JS-hostile construct or a mis-ordered branch. The one worth
   naming: a client filter that names the owner field cannot displace the derived
   value, which is the concrete form of "the caller cannot address this channel".
6. ✅ **Made loud 2026-08-12; the value is a deployment's to set.**
   `OwnerScope.elevatedGroups` defaults to `[]`, and nothing outside its own
   module called `setElevatedGroups` — so every deployment silently got "no
   caller is ever elevated", meaning an administrator sees only their own rows.

   **The framework cannot supply the value and should not try.** Which groups are
   operators is a deployment fact; a default of `["Admin"]` would be a guess that
   silently grants cross-owner reads to whoever happens to hold that group name.
   What the framework owed here was a signal, not a value, and it had none.

   `OwnerScopeDiagnostics.warnIfNoElevatedGroups` now fires once per view, from
   both resolver registration sites, whenever a view declares `@owner` and no
   group is exempt. It names the view, the field, and the consequence — an
   operator told only "configure elevated groups" has no reason to treat it as
   urgent. In core rather than per-adapter so the rule and its wording are stated
   once. Six tests, and the file pins its own `LOG_LEVEL` because it asserts on
   emitted output.

   **The carrier is the environment, and that was not a style choice.** A cloud
   deployment is two kinds of process. The deploy program bakes the DynamoDB
   predicate into resolver source; stamping and the SQL-backed reads run later
   inside separate function runtimes it never enters. A value set only in the
   deploy program reaches the first and not the second — and what that produces
   is a **wrong write**, not a narrow read: an operator acting on a customer's
   behalf has the row stamped with their own id, because the runtime believes
   nobody is elevated.

   So `elevatedGroups()` resolves as *explicit `setElevatedGroups` wins, else
   `REVENTLESS_ELEVATED_GROUPS`, else empty* — the same shape as
   `Logger.effectiveMin()`, for the same reason. It is a function rather than a
   readable `ref` because the answer depends on the environment as well as on
   what was set, and freezing whichever half was consulted first is exactly the
   bug. Seven tests, including the two precedence cases and the hand-edited-value
   shapes (`"Admin, Support ,Ops"`, `"Admin,,  ,"`).

   Two things this rules out, both worth not re-deriving. A field on either
   `MakeWithConfig` functor breaks every consumer and, on AWS, would be restated
   per plugin stack — the "two lists that drift" failure the baked manifest
   already designed around. And teaching the plugin-root generator to emit a
   `setElevatedGroups` call fixes only the deploy half, so it would look like a
   fix while leaving the wrong-stamp bug in place.

   ⚠️ **Still open, and it is wave-5 work:** the AWS runtime builder must pass the
   variable to every Lambda. The seam exists —
   `Util_LambdaLogging.applyLogLevelDefault` is applied to all of them from one
   shared helper (`RuntimeEnvironment_Lambda.res:238`) precisely so bespoke
   builders cannot diverge; an `applyElevatedGroupsDefault` belongs beside it.
   Until that lands, an AWS deployment configures the deploy program only, and
   its Lambdas still believe nobody is elevated. Note also that a baked value
   makes a change to the list a redeploy, not a restart.
7. `ownerField` on `queryableDef` / `commandDef`, and the baked-manifest copy
   check.
8. The `@owner` PPX shorthand, replacing the hand-written `@s.matches` at each
   call site.

Steps 1–5 are all verifiable without deploying: the AppSync arm is checked by
evaluating its generated source, which is why it could land before a stack run
rather than after. What still needs a deployed stack is the *end-to-end* §9
matrix — and that run is blocked on step 6, because with no elevated groups
configured the "an elevated token sees all rows" assertion cannot pass. Step 8
changes no behaviour and can slip.
