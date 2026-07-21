# Element-Level `comp` for Event-Collector Dispatch

**Status:** Complete (2026-07-21)

**Created:** 2026-07-21

Follow-up to `done/queryable-dispatch-log-annotations.md` (see its **Follow-up** section) and
step 1 of `docs/analysis/telemetry-substrate.md`.

## Problem

The dispatch boundary annotates `comp` on every log line of a handler invocation, which makes two
components hosted in one runtime process separable by field. For aggregates that works: `comp` is
`AggregateRuntime(<aggregateName>)` and the inner name *is* the element.

For event collectors it does not. Both multi-component dispatchers key `comp` by the **runtime
group**, not the element:

- `EventCollectorRuntime_Builder_Single` — one `AllReadModels`-style Lambda hosts every read model /
  state-view slice / side-effect handler in the group; every one of them logs
  `comp = EventCollectorRuntime(AllReadModels)`.
- `AggregateRuntime_Builder_Common` — event collectors nested under an aggregate (the EventMapper
  path) log `comp = AggregateRuntime(<parentAggregate>)`.

So `| filter comp like /Customers/` isolates an aggregate's lines but cannot isolate a read model's.

A second, quieter consequence: the `plugin` field. `LogPrefix.resolvePlugin` resolves the inner name
against the component→plugin registry; `AllReadModels` is not a component, so resolution falls
through to the **ambient** `currentPluginName` — whichever plugin happened to be constructed last.
In a shared Lambda hosting collectors from several plugins the `plugin` field is therefore
arbitrary today.

The single-component-per-Lambda paths (`PerEventCollector`, the local builders) already annotate a
per-element name, but pass it **bare** (`CustomersReadModelEventColl`). `extractInnerName` needs a
`Kind(Name)` shape, so those also fall through to the ambient plugin.

## Approach

1. **Carry the element name with the handler.** In both multi-component dispatchers the registry is
   `dict<array<effectHandler>>` keyed by source URN. Widen the element to a record that pairs the
   handler with the `comp` computed at registration time (where the event collector's own resource
   is in hand), and annotate per handler at dispatch instead of once per invocation.
2. **One `comp` shape for every event-collector path** — `EventCollector(<resourceName>)`, e.g.
   `EventCollector(CustomersReadModel)`. Applies to the two multi-component dispatchers and to the
   per-component builders (which switch from the bare name to the parenthesized form).
3. **Resolve the plugin from a decorated component name.** Registered component names are bare spec
   names (`Customers`); event-collector resource names are `<SpecName><Kind>`
   (`CustomersReadModel`). Add a final candidate to `LogPrefix.resolvePlugin`: longest registered
   component name that is a **prefix** of the inner name. Generic (no per-kind suffix table, which
   `LogPrefix` could not reach anyway — it sits below `ComponentType`), tried only after the
   existing candidates, so it can only turn a miss into a hit.

The framework's own dispatch bookkeeping lines (`found N handler(s) for <urn>`, `no handler found`)
stay on the group `comp` — they describe the group, not an element.

## Scope

| File | Change |
|---|---|
| `core/src/adapter/Runtime/EventCollectorRuntime_Builder_Single.res` | pair name with handler; per-handler `comp` |
| `core/src/adapter/Runtime/AggregateRuntime_Builder_Common.res` | same, for the nested event-collector registry |
| `core/src/adapter/Runtime/EventCollectorRuntime_Builder_PerEventCollector.res` | parenthesized `comp` |
| `local/src/adapter/Runtime/LocalEventCollectorRuntime_Builder.res` | parenthesized `comp` |
| `local/src/adapter/Runtime/LocalAggregateRuntime_Builder.res` | parenthesized `comp` (event-collector arm) |
| `spec/src/LogPrefix.res` | prefix-match candidate in `resolvePlugin` |
| `docs/guides/cloudwatch-logs-insights.md` | document the event-collector `comp` shape |

## Acceptance

- Two read models hosted in the same `AllReadModels` runtime are separable purely by `comp`.
- A read model's application-handler log line carries `comp = EventCollector(<Name>ReadModel)` and
  the `plugin` field of its **owning** plugin, not the last-constructed one.
- Every event-collector dispatch path (shared, per-component, aggregate-nested, local) emits the
  same `comp` shape.
- Existing aggregate / command-topic / extension-point `comp` values are unchanged.
- Zero compiler warnings.

## Follow-up — bare `comp` strings resolve no plugin

The single-component-per-Lambda strategies outside the event-collector paths
(`PluginRuntime_Builder_{Single,Micro}`, `AggregateRuntime_Builder_Micro`,
`ExtensionPointRuntime_Builder_PerExtensionPoint`, and the local command-topic /
command-generator arms) still pass `comp` **bare** — `CustomersReadModelEventColl`, not
`Kind(Name)`. `extractInnerName` requires the parenthesized shape, so those invocations
fall through to the ambient plugin name, which is `None` once construction has finished:
their log lines carry `comp` but **no** `plugin` field.

Two ways out, neither taken here: give those builders the parenthesized shape too (matching
what this plan did for event collectors), or let `extractInnerName` fall back to the whole
comp string when it has no parens. The second is one line but widens prefix matching to every
bare comp in the codebase (`AggregateRuntime`, `PluginRuntime_Builder`, `__MODULE__`), so it
wants its own think. Filed rather than folded in — it is a different set of components than
the one this plan is about.

## Non-goals

- Changing the `comp` shape for non-event-collector components.
- Adding a separate `component` field alongside `comp` — one field, one meaning.
- Threading a new labeled argument through the shared `Runtime.forEventCollector` signature; the
  name is derivable from the component resource already passed in.
