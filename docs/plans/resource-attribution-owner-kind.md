# Owner-kind attribution for storage and channel adapters

**Status:** Planned (2026-07-22) — not started.
**Owner:** Martin
**Follows:** `docs/plans/done/resource-attribution-tag-schema.md`, which established the tag schema
and closed the same gap for Lambdas. This plan closes it for the remaining resource classes.

**Motivation:** `reventless:kind` is meant to carry the **modelling kind of the component that owns
the resource** (Aggregate, ReadModel, StateViewSlice, …), independent of `reventless:role`, which
carries the deployment piece (EventLog, QueryDb, Runtime, …). That separation holds today for every
Lambda — `RuntimeEnvironment_Lambda.makeFromCodeAsset` takes a required `~componentKind` — and for
plugin/platform substrate. It does **not** hold for the storage and channel adapters, which provision
most of the stateful infrastructure:

```rescript
// QueryDbStorage_DynamoDb.res — kind and role land on the same word
AWS.Tags.make(~name, ~kind=ReventlessCore.QueryDb.componentType, ~role=QueryDb)
```

Two independent causes:

1. **The adapter is never told who owns it.** `QueryDbStorage_DynamoDb.make` receives a `~name`
   string and nothing else. The owner is fixed by whichever builder applied the piece functor, one
   or two levels up.
2. **`ComponentType.t` is a mixed enum.** It holds both modelling kinds (`Aggregate`, `ReadModel`,
   `StateViewSlice`, …) and piece names (`EventLog`, `QueryDb`, `CommandTopic`, `EventTopic`,
   `EventCollector`). An adapter passing "its own" component type is naming the *piece*, so `kind`
   necessarily collides with `role`.

**Why this is worth doing.** The piece-to-owner fan-in is wide, so the lost fact is not recoverable
by convention (verified by tracing `*_Builder.Make` applications in `reventless/core/src`):

| Piece | Component kinds that instantiate it |
|---|---|
| `QueryDb` | ReadModel, StateViewSlice, AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice, Counter (×2) |
| `EventCollector` | Aggregate, ReadModel, StateViewSlice, AutomationSlice, OutboundTranslationSlice, Plugin, Platform_Admin |
| `CommandTopic` | Aggregate, ExtensionPoint, DCB (sync + async) |
| `EventTopic` | EventLog, DcbEventLog, ExtensionPoint |
| `EventLog` | Aggregate only |

A DynamoDB table tagged `reventless:kind = QueryDB` may belong to any of six component kinds, and no
other tag narrows it. Only `EventLog` has a single owner — see Non-goals for why that does *not*
justify a shortcut.

**Secondary defect, fixed by the same change.** At these call sites no `~component` is passed, so
`reventless:component` defaults to the suffixed resource name (`ProductsQueryDb`) rather than the
component stem (`Products`). The owner's spec name travels the same channel as its kind, so one
change fixes both.

**Affected:** the piece adapter interfaces in core — `EventLog_Adapter.Storage`,
`QueryDb_Adapter.Storage`, `CommandTopic_Adapter.Channel`, `EventTopic_Adapter.Publisher`,
`EventCollector_Adapter.Channel` — their piece builders, every builder that applies those functors,
and the implementations in **both** platforms (`reventless/aws`, `reventless/local`). Unlike the
preceding plan, this one cannot stay inside `reventless/aws`.

---

## The approach

The piece builders already know their owner: `QueryDb_Builder.Make(Spec, …)` is applied from inside
`ReadModel_Builder`, `StateViewSlice_Builder`, `Counter_Builder`, and so on. So the owner's identity
exists at the point of functor application and merely needs a channel down to the adapter.

Introduce one small record in core beside the attribution vocabulary:

```rescript
// ResourceAttribution.res
type owner = {kind: ComponentType.t, name: string}
```

Thread it from the owning builder → piece builder → adapter `make`, and have the AWS adapters pass
`~kind=owner.kind` and `~component=owner.name` to `AWS_Tags.make`.

**Optional first, required last.** Add `~owner` as an optional argument so every existing
implementation keeps compiling, populate all call sites, then make it required in the final phase.
That is the same discipline that made the Lambda fix durable: once required, a future adapter cannot
silently fall back to naming its own piece.

---

## Phases

### 1. Define `owner` and widen the adapter interfaces (optional argument)

Add the record to `ResourceAttribution`; add `~owner: owner=?` to the five adapter module types and
their piece builders. Update the AWS and local implementations to accept and ignore it. No tag
behaviour changes yet — this phase is purely the channel, and should be a no-op diff in emitted
tags.

### 2. Populate at the owning builders

Pass `~owner={kind: <the owner's ComponentType>, name: Spec.name}` at every `*_Builder.Make`
application listed in the fan-in table: Aggregate, ReadModel, StateViewSlice, AutomationSlice, both
translation slices, Counter, ExtensionPoint, DcbEventLog, Dcb, Plugin, Platform_Admin.

Note `EventTopic` nests one level deeper (inside `EventLog_Builder` / `DcbEventLog_Builder`), so its
owner must be forwarded through the enclosing piece builder rather than re-derived.

### 3. Consume in the AWS adapters

Replace the piece-equal `~kind` at the storage/channel call sites with the threaded owner kind, and
pass `~component=owner.name`. After this, two QueryDb tables owned by a ReadModel and a
StateViewSlice carry different `reventless:kind`, and both carry a clean component stem.

- Guard: extend `AWS_TagsTest` with a case asserting exactly that, mirroring the existing
  "one piece role spans several component kinds" test.

### 4. Make `~owner` required

Drop the optional default once every call site supplies it, so the compiler enforces attribution for
any adapter added later.

---

## Non-goals

- **Splitting `ComponentType.t` into separate modelling-kind and piece enums.** That is the deeper
  cleanup behind cause (2), but it touches naming, serialization and the plugin generator, and
  `Role.t` already carries the piece axis for attribution purposes. The piece entries in
  `ComponentType.t` simply become vestigial *for tagging*; leave the enum alone here.
- **Hardcoding `EventLog` → `Aggregate`.** It is the one 1:1 mapping today and would be correct on
  the day it is written, but correct by coincidence: the first other applier of `EventLog_Builder`
  makes the tag lie silently, with nothing to catch it. Thread it like the rest.
- **An ambient per-component context** (the trick used for plugin/platform in the preceding plan).
  It needs a choke point around every component construction. `Component.make` is that point, but it
  is an `@new external` into hand-written `Component.mjs` whose `~construct` is polymorphic and
  invoked by the JS class itself, so wrapping it means editing that file — and regenerating it is
  known to produce a broken circular require. Fewest lines, worst place to be wrong.
- **Renderer or downstream ingest work.** This plan only makes the framework emit the correct fact.

## Done when

- `reventless:kind` names the owning component's modelling kind on every framework-created resource,
  not the piece — verifiable by two same-role resources under different owner kinds carrying
  different `kind`.
- `reventless:component` carries the component stem, not the suffixed resource name, at the
  storage/channel adapters.
- `~owner` is a required argument on the five adapter interfaces.
- Both platforms compile against the widened interfaces; AWS tag tests cover the new guarantee.
