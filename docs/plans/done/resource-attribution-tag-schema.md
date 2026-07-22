# Resource attribution tag schema — a complete, honest deploy-tag vocabulary

**Status:** Complete (2026-07-21) — all four phases landed.
**Owner:** Martin

## Progress log (2026-07-21)

**Landed**

- **New `reventless/core/src/ResourceAttribution.res`** — `Scope` (Component/Plugin/Platform),
  `Role` (the piece vocabulary, with `Other(string)` escape hatch), and the ambient deploy-time
  plugin/platform context. This is phase 4's "one source of truth", done first so phases 1–3 could
  consume real types instead of free strings.
- **Phase 1** — `AWS_Tags.make` now emits the eight-key schema (seven `reventless:*` + bare `Name`);
  `Type`/`Plugin` dropped, `Environment` → `reventless:environment`. `makeDict` exposes the raw dict
  for bindings that post-process tags (`EC2.Vpc`). All 20 pre-existing call sites migrated.
- **Phase 2** — the Lambda kind hardcode is fixed. `makeFromCodeAsset` takes a **required**
  `~componentKind`, threaded from all 25 runtime-builder call sites.
- **Phase 3** — every taggable creator in `reventless/aws/src` now passes `~tags`: all Lambda
  execution roles and managed log groups, the AppSync data-source roles, the merged API and each
  source API, the Cognito user pool, the managed IAM policies, the plugin DLQ role, the task bucket,
  the VPC, the heartbeat and change-feed EventRules, and the UI-hosting bucket / ACM certificate /
  CloudFront distribution. Bindings gained `IAM.Role.makeWithDefaultPolicy(~tags=?)`,
  `IAM.Policy.args.tags`, `Cloudwatch.EventRule.args.tags` and `AppSync.GraphQLApi.args.tags`.
- **Tests** — `AWS_TagsTest` (10) and `ResourceAttributionTest` (7), both green; AWS suite 275/275.

**Correction to the plan's phase-2 premise.** The plan assumed `~unitKind` already carried the true
component kind. It does not: `Monitoring.unitKind` is documented as *"the ROLE of a provisioned
execution unit"* and grades units by what their failure means — `CommandHandler` covers aggregates,
state-change slices *and* extension points alike. Threading it into `reventless:kind` would have left
an Aggregate and a StateChangeSlice indistinguishable. Hence the separate, required `~componentKind`.
Being required is itself the regression guard: the old hardcode cannot silently come back.

**Consequence for phase 4.** Because `unitKind` (failure semantics) and `Role` (deployment piece)
measure different axes, they were deliberately *not* merged — a `Runtime` role can be a
CommandHandler, a Projection or a Reactor. Both facts are worth carrying and neither derives from the
other; `ResourceAttribution` documents the distinction rather than collapsing it.

**Deliberately left untagged — AWS provides no tag support for these resource types**

Lambda EventSourceMappings and Permissions, CloudWatch LogMetricFilters and EventTargets, AppSync
Resolvers and DataSources, inline `IAM.RolePolicy` (only *managed* `IAM.Policy` is taggable),
Route53 Records, S3 BucketPolicy / PublicAccessBlock / OriginAccessControl, and Cognito
UserPoolClient. The "no framework resource with an empty `reventless:*` set" criterion cannot cover
these; each is attributable only through its parent (function, log group, API, role, bucket, pool).
Note the ReScript binding for `IAM.RolePolicy` carries a `tags?` field that AWS ignores — do not
read its presence as tag support.

**Residual gap worth knowing about.** `reventless:kind` is exact for every Lambda (phase 2 threads it)
and for plugin/platform substrate. For the storage and channel adapters — EventLog, QueryDb,
CommandTopic, EventTopic, EventCollector — the adapter is not told which model component owns it, so
it passes its own `ComponentType`, leaving `kind` piece-equal there. That is a strict improvement on
the old schema (role, scope, plugin, platform and environment are all now correct) but not the full
promise. Closing it needs an owner-kind threaded into those adapters, or an ambient per-component
context. The natural choke point would be `Component.make`, but it is an `@new external` straight to
hand-written `Component.mjs` with a polymorphic `~construct` callback, so there is no clean ReScript
seam to wrap — hence deferred rather than bodged.
**Motivation:** Every deployed AWS resource the framework creates *can* carry attribution tags via
`AWS_Tags.make`, but the current schema is lossy and partly wrong, so a downstream reader cannot
reliably answer "which model component owns this resource, in what role, at what scope". Three
concrete defects, all code-verified in `reventless/aws/src`:

1. **Every runtime Lambda is mis-tagged.** `RuntimeEnvironment_Lambda.res` calls
   `AWS.Tags.make(~name, ReventlessCore.CommandTopic.componentType)` — a hardcoded `CommandTopic`
   kind — for *every* Lambda it provisions, whatever the unit actually is (an Aggregate runtime, a
   StateViewSlice runtime, a SideEffect handler, a Task, an extension-point runtime, …). The true
   kind (`~unitKind`) is already threaded into the runtime builders that call this adapter; it just
   never reaches the tag. So `reventless:role` and `reventless:kind` on a Lambda are both the
   literal string `"CommandTopic"`, and only `reventless:component` distinguishes one Lambda from
   another.
2. **`reventless:role` duplicates `reventless:kind`.** `AWS_Tags.make` sets both to the same
   `componentType->toString`. They are meant to carry two *different* facts: the **piece role** (the
   V2 deployment piece — `EventCollector`, `QueryDb`, `Runtime`, `CommandTopic`, …) and the owning
   **model-component kind** (the V1 modelling concept — `Aggregate`, `StateViewSlice`, …). Today one
   value stands in for both, so neither question can be answered.
3. **No scope, no platform, wrong plugin, and most resources carry no tags at all.**
   - There is no `reventless:scope` key, so nothing distinguishes a *component-owned* resource from
     *plugin* substrate (a DcbEventLog, a shared DLQ) or *platform* substrate. That
     component/plugin/platform distinction is the one an inventory needs to roll resources up to
     the element that owns them.
   - `reventless:plugin` is set from `Pulumi.getProjectName()` — the **stack/project** name
     (`online-shop-ordering-aws`), not the domain plugin name (`Ordering`). A reader has to reverse
     the project naming convention to recover the plugin.
   - There is no `reventless:platform` key.
   - Tagging is opt-in per call site, and many creators pass none: IAM roles + role policies,
     CloudWatch LogGroups + LogMetricFilters, CloudWatch EventRules (heartbeat / scheduler), S3
     buckets (task + hosting), EventSourceMappings, VPC/EC2, Cognito, AppSync merged API + resolvers,
     CloudFront / ACM / Route53. These land in the account untagged and therefore unattributable.

**Affected:** `reventless/aws/src/adapter/AWS_Tags.res` (the helper), `AWS.res` (its re-export),
`reventless/aws/src/adapter/Runtime/*` + `plugin/runtime/*` (the runtime builders that hold
`~unitKind`), and every creator that provisions a resource without tags (audit list below). No
change outside `reventless/aws`. Backends other than AWS express the same schema as native labels
(`reventless.io/*` on Kubernetes) — the K8s renderers already emit an `Adapter.resource` record with
`service`/`role`/`region`, i.e. the same vocabulary, so this plan defines the *schema* both honour.

---

## The target schema

`AWS_Tags.make` produces this key set (each key present on every framework-created resource):

| Key | Meaning | Today |
|---|---|---|
| `reventless:platform` | the platform name | **missing** |
| `reventless:plugin` | the **domain plugin** name (never the stack/project) | = project name |
| `reventless:component` | the model component stem (`Products`, not `ProductsQueryDb`) | ok, but Lambda name is the mis-tag vector |
| `reventless:kind` | the **V1 model-component kind** (`StateViewSlice`) | = role (duplicate) |
| `reventless:role` | the **V2 piece role** (`QueryDb` / `EventCollector` / `Runtime` / …) | = kind (duplicate) |
| `reventless:scope` | `component` \| `plugin` \| `platform` | **missing** |
| `reventless:environment` | the stack/env the resource is deployed into | today's bare `Environment` |
| `Name` | the AWS-console display name (special UI meaning) | kept — the one earned bare key |
| ~~`Environment`~~ | — | **renamed** to `reventless:environment` (a framework fact, not an external key) |
| ~~`Type`~~ | — | **dropped**: an exact duplicate of `reventless:kind` |
| ~~`Plugin`~~ | — | **dropped**: an exact duplicate of `reventless:plugin` |

`scope = plugin | platform` rows carry `component` empty by definition: substrate is attributed to
its level, not to a fabricated component.

### Naming consistency (the rule this schema follows)

Today's key set mixes two namespaces for no reason — `reventless:plugin` sits beside a bare `Plugin`
holding the *same* value, `reventless:kind` beside a bare `Type`, and the casing even slips
(`Environment` the tag vs. `environment` in prose). A reader can't tell which key is authoritative.
The rule:

- **Every fact the framework's own tooling reads is namespaced `reventless:<key>`, lower-case**, and
  appears exactly once. No framework fact is also emitted under a bare alias.
- **A bare key is justified ONLY when the key name itself is load-bearing to an external system** —
  i.e. the value would be lost if namespaced. Exactly one key clears that bar: `Name`, which the AWS
  console reads by that literal spelling to populate the resource-name column (namespace it and the
  console shows blanks). It is the sole bare exception.
- **`Environment` does NOT clear that bar, so it becomes `reventless:environment`.** The stack/env is
  a framework fact like plugin/component; keeping it bare was the same inconsistency this rule
  exists to remove. AWS cost allocation groups by *any* activated tag key, so a namespaced
  `reventless:environment` is a first-class cost-allocation dimension — the bare spelling buys
  nothing. (An org that mandates a bare `Environment` via a tag policy points that policy at
  `reventless:environment`; that is an org-level concern, not a reason to fork the framework schema.)
- **The redundant duplicates go.** `Type` and `Plugin` carry nothing `reventless:kind` /
  `reventless:plugin` doesn't; dropping them removes the "which one is right?" ambiguity. (If an
  external dashboard is found to read a dropped bare key, migrate it to the namespaced key rather
  than keep the alias — the whole point is one authoritative name per fact.)
- **On Kubernetes the same facts are `reventless.io/<key>` labels** — the platform-idiomatic form of
  the identical namespace, so the two backends carry one vocabulary, spelled each platform's way.

Net: one namespace for framework facts (`reventless:*` / `reventless.io/*`), a single bare exception
(`Name`, earned by AWS-console behaviour), and no key duplicated across the two.

---

## Phases (each independently shippable; the default output stays a superset, never a regression)

### 1. Split `role` from `kind`, add `scope` + `platform`, fix `plugin` — the helper

Grow `AWS_Tags.make` from `(~name, componentType)` to carry the four facts it currently collapses:

```rescript
// AWS_Tags.make(~name, ~plugin=?, ~kind, ~role, ~scope, ~platform=?)
//   kind     : ComponentKind.t   — the V1 model-component kind
//   role     : string            — the V2 piece role (EventCollector, QueryDb, Runtime, …)
//   scope    : Component | Plugin | Platform
//   plugin   : the DOMAIN plugin name; defaults to getProjectName() only when not supplied
//   platform : the platform name
```

- **Additive/back-compat:** keep the old positional `(~name, componentType)` arity working as a
  thin shim that fills `role = kind = componentType`, `scope = Component`, so no call site breaks in
  the same release. Migrate call sites in phase 3, then remove the shim in a later release.
- `reventless:plugin` prefers the passed domain plugin, falling back to `getProjectName()` only when
  a caller genuinely has none — so a correctly-wired caller stops leaking the stack name.
- Unit-test the key set directly (`AWS_TagsTest`): all seven `reventless:*` keys present; `role` and
  `kind` independent; `scope=Plugin`/`Platform` ⇒ empty `component`.

### 2. Fix the Lambda kind hardcode — thread `~unitKind` to the tag

`RuntimeEnvironment_Lambda` already receives the real kind from its builder (`~unitKind` reaches the
monitoring registry today); route the same value into `AWS.Tags.make` instead of the hardcoded
`CommandTopic.componentType`, and pass the piece `role` (`Runtime`) and `scope = Component`. After
this, two Lambdas of different kinds carry different `reventless:kind`, and every Lambda reads
`reventless:role = Runtime` rather than `CommandTopic`.

- Guard: a builder-level test asserting an Aggregate-runtime Lambda and a StateViewSlice-runtime
  Lambda emit distinct `reventless:kind` values and both `role = Runtime`.

### 3. Tag the untagged creators (audit → mechanical)

Once the helper carries the right facts, pass `~tags` at the creators that pass none today. Audit
list (grep-verified, `reventless/aws/src`): IAM roles + role policies, LogGroups + LogMetricFilters,
EventRules (heartbeat / scheduler), S3 buckets (task + hosting), EventSourceMappings, Cognito,
AppSync merged API + resolvers, CloudFront / ACM / Route53, VPC/EC2. Each of these is
substrate — `scope = Plugin` or `Platform`, `component` empty — with a `role` naming the piece
(`DeadLetter`, `LogGroup`, `Scheduler`, `Hosting`, …). Mechanical once phase 1 lands; the value is
that "everything this plugin deployed" stops having holes.

### 4. `role`/`scope` vocabulary — one source of truth

The piece roles (`EventCollector`, `QueryDb`, `Runtime`, `CommandTopic`, `EventTopic`, `DeadLetter`,
…) and the `scope` enum should be a named type in core, not free strings at each call site, so the
tag vocabulary and the monitoring-registry vocabulary cannot drift. Define them once (beside
`ComponentKind`), have both the tag helper and the registry consume them.

---

## Non-goals

- **No new infrastructure.** This is metadata on resources the framework already creates.
- **No renderer/ingest work.** Downstream readers of these tags live in their own repos; this plan
  only makes the framework *emit* a complete, correct schema. Kubernetes label emission of the same
  schema is a follow-up once the AWS shape is settled (the K8s adapter already carries the values).
- **No new bare keys.** `Name` is the sole bare exception; `Environment` → `reventless:environment`,
  and the redundant bare `Type`/`Plugin` are dropped in favour of their `reventless:` twins (see
  Naming consistency).

## Done when

- `AWS_Tags.make` emits all seven `reventless:*` keys, with `role` and `kind` independent, `scope`
  set, `plugin` the domain plugin, and `platform` present.
- No framework-created Lambda reports `reventless:kind = "CommandTopic"` unless it truly is one;
  `reventless:role = Runtime` on every runtime Lambda.
- The audit-list creators carry substrate tags; a stack export has no framework resource with an
  empty `reventless:*` set.
- The role/scope vocabulary is a shared named type, consumed by both the tag helper and the
  monitoring registry.
