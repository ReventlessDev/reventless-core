---
title: Directives
date: 2026-06-16
---

# Directives

Directives are Reventless's **typed escape hatch for side effects** at a plugin
boundary. An [ExtensionPoint](../components/extensionpoint.md) and an
[Extension](../components/extension.md) mapping normally translate between events
and commands — both of which stay *inside* the event-sourced system. A directive
lets a mapping reach *outside* that system: it runs an arbitrary `async` handler
(call an external API, send a notification, create a schedule, emit a metric)
without inventing a fake command or event for it.

This guide covers what directives are, when to use them, and — most importantly —
the difference between **ExtensionPoint directives** and **Extension directives**,
which share a name and a type but have deliberately different capabilities.

---

## What a directive is

Every ExtensionPoint and Extension `Spec` declares three `@schema` types:

```rescript
@schema type command   // requests that flow INTO a plugin
@schema type event     // facts that flow OUT of a plugin
@schema type directive // side effects the mapping performs at the boundary
```

`command` and `event` are *messages that stay in the system* — they are encoded,
logged, routed to topics, projected, and replayable. A **directive** is different:
it is the payload of a `HandleDirective(handler, directive)` action that a mapping
returns. When the runtime sees that action it simply **calls `handler(directive)`**
as a fire-and-forget side effect. Nothing is published, logged to the event store,
or replayable.

A mapping returns a list of actions. Most route messages back into the system;
`HandleDirective` is the one that escapes it:

```rescript
// An ExtensionPoint mapping's mapOutgoingEvent:
switch event {
| OrderShipped({orderId}) => [
    PublishEvent(orderId, ExtensionPoint.OrderCompleted({orderId})),     // → stays in-system
    HandleDirective(notifyHandler, NotifyWarehouse({orderId})),          // → escapes the system
  ]
}
```

The directive **type** is owned by the ExtensionPoint and *mirrored* by any
Extension that connects to it — the Extension's `Spec.directive` is type-checked
against the ExtensionPoint's, so both sides speak the same directive vocabulary.
A protocol with no directives declares `type directive = unit`.

---

## When to use a directive (and when not to)

Use a directive when the boundary needs to cause an effect that **is not itself a
domain state change**:

- call a third-party / non-Reventless HTTP API
- send an email, push, or chat notification
- create or delete a [Schedule](/framework/runtime-components/scheduler) (timer) — *ExtensionPoint
  side only; see below*
- emit telemetry / metrics, invalidate an external cache
- bridge an event to a system that has no command of its own

**Do not** use a directive when the effect *is* a domain change. If something in
your domain should happen, publish a `command` (or let an event drive a
projection) so it stays event-sourced, audited, and replayable. Directives have
**no audit trail, no retry, and no replay** — they are an explicit step outside
the guarantees the rest of the framework gives you. Reach for one only when a
command or event genuinely does not fit.

---

## ExtensionPoint directives

Declared on the ExtensionPoint spec, raised from the **ExtensionPoint mapping**
(`*_ExtensionPointMapping.res`). An ExtensionPoint runs on the provider plugin's
command/event-dispatch path, which the framework already wires with a scheduler
and query engine — so the EP component threads them into the directive handler:

```rescript
// ReventlessInfra.ExtensionPointMapping
type directiveHandler<'directive> = (
  Reventless.Schedule.create,        // create a timer
  Reventless.Schedule.delete,        // cancel a timer
  Reventless.QueryEngine.operations, // read projections
  'directive,
) => promise<unit>
```

It can be returned from **both** mapping directions:

- `mapIncomingCommand` → `commandAction` carries `HandleDirective(handler, directive)`
- `mapOutgoingEvent` → `eventAction` carries `HandleDirective(handler, directive)`

Because it has `createSchedule`/`deleteSchedule`/`queryEngine`, an ExtensionPoint
directive is the right place for infra-bound effects. This is exactly how the
framework's own admin plugin schedules a "disconnect" timer when a plugin connects
(`reventless-core/src/admin/PluginExtensionPoint_Plugin.res`):

```rescript
let directiveHandler = async (createSchedule, _deleteSchedule, _queryEngine, directive) =>
  switch directive {
  | CreateDisconnectSchedule(id, timeout) =>
    await createSchedule({
      name: id,
      rate: timeout->ScheduleOps.minutesFromNow,
      // …
    })
  | DeleteDisconnectSchedule(id) => await deleteSchedule(id)
  }

// …raised from the mapping:
HandleDirective(directiveHandler, CreateDisconnectSchedule(id, interval + 2))
```

The generated mapping stub (from the VS Code authoring surface) looks like this and
is the place you wire your handler:

```rescript
let handleDirective: directiveHandler<ExtensionPoint.directive> = (
  _createSchedule, _deleteSchedule, _queryEngine, directive,
) =>
  switch directive {
  | ExtensionPoint.NotifyOps(_) => Promise.resolve() // TODO: handle NotifyOps
  }
```

---

## Extension directives

Declared on the same protocol but raised from the **Extension mapping**
(`*_Extension.res`). An Extension runs on the consumer plugin's EventCollector
path, which the framework currently wires with only a query engine (no scheduler) —
and even that isn't passed to the directive handler. So the handler is a bare async
function with **no scheduler and no query-engine argument**:

```rescript
// Reventless.Handler.handler
type handler<'directive> = 'directive => promise<unit>
```

It can be returned from both Extension directions:

- `mapIncomingEvent` → `incomingCommandAction` carries `HandleDirective(handler, directive)`
- `mapOutgoingEvent` → `outgoingCommandAction` carries `HandleDirective(handler, directive)`

Use Extension directives for **infra-free, fire-and-forget effects**: calling an
external API, emitting a metric, logging, notifying another system. The generated
stub:

```rescript
let handleDirective: Reventless.Handler.handler<ExtensionPoint.directive> = directive =>
  switch directive {
  | ExtensionPoint.FlushCache => Promise.resolve() // TODO: handle FlushCache
  }
```

:::note Reads are still possible
`mapIncomingEvent` itself receives `queryEngine` and `pluginDef`. If you define the
handler *inline* inside `mapIncomingEvent` (instead of at module level) it closes
over them, so query-based side effects work. Scheduling does not — extensions are
never handed a scheduler.
:::

### "I'm in an extension and need to create a schedule"

You can't, directly — and that's by design. Do one of:

1. **Route to a write-side command (idiomatic).** Have `mapIncomingEvent` return
   `PublishAggregateCommand` / `PublishStateChangeSliceCommand` to a local
   component, and let that component — or an
   [AutomationSlice](../components/automationslice.md), the framework's timer
   primitive — own the schedule.
2. **Move the directive to the ExtensionPoint side.** If the schedule logically
   belongs at the boundary, declare and raise it from the *provider's*
   ExtensionPoint mapping (whose `directiveHandler` *does* get `createSchedule`).
   The extension publishes a protocol command that the EP maps into that directive.

---

## ExtensionPoint vs Extension directives

Same `directive` type, same `HandleDirective` constructor name, deliberately
different handler capabilities:

| | **ExtensionPoint directive** | **Extension directive** |
|---|---|---|
| Declared in | ExtensionPoint spec (`@schema type directive`) | mirrored from the EP it connects to |
| Raised from | `*_ExtensionPointMapping.res` | `*_Extension.res` |
| Directions | `mapIncomingCommand`, `mapOutgoingEvent` | `mapIncomingEvent`, `mapOutgoingEvent` |
| Handler type | `directiveHandler<'d>` = `(Schedule.create, Schedule.delete, QueryEngine.operations, 'd) => promise<unit>` | `Reventless.Handler.handler<'d>` = `'d => promise<unit>` |
| Scheduler access | ✅ `createSchedule` / `deleteSchedule` | ❌ none |
| Query engine | ✅ passed to the handler | ⚠️ only via `mapIncomingEvent` closure |
| Runs on | provider plugin's command/event-dispatch path | consumer plugin's EventCollector path |
| Best for | scheduling, infra-bound effects at the boundary | external calls, notifications, metrics |

Both mappings are app-authored — apps define their own extension points. The
asymmetry is **not** about who writes the code; it is about **where each mapping is
wired**. The provider's command/event-dispatch path already has a scheduler and
query engine in scope, so the EP component threads them into its directive handler.
The consumer's EventCollector path is wired with only a query engine today, and the
extension handler is handed neither. By convention an extension stays a thin router
— translating cross-plugin events into local commands and leaving infra-bound
effects to the write-side, a `SideEffectHandler`, or an `OutboundTranslationSlice`
— so the missing scheduler is rarely a real limitation, but it is a wiring gap, not
a hard boundary.

---

## Directives vs. translation slices and side-effect handlers

Directives are not the only way Reventless reaches outside the event-sourced
system. They sit in a family of **boundary / anti-corruption** mechanisms that all
implement Event Modeling's *Translation* pattern — but at different seams, with
very different guarantees. Knowing which to reach for matters.

### Two different boundaries

Reventless has two "translation" seams, and the docs use the word *translation*
for both:

- **Translation slices** ([InboundTranslationSlice](../components/inboundtranslationslice.md)
  / [OutboundTranslationSlice](../components/outboundtranslationslice.md)) translate
  between the system and the **external / non-Reventless world** (webhooks,
  third-party APIs).
- **ExtensionPoint / Extension mappings** translate between **two Reventless
  plugins** (the cross-plugin seam). A **directive lives inside that second kind of
  mapping** — it is one of the actions the mapping can return.

So directives and translation slices are siblings under "anti-corruption layer at
a boundary," but a directive is the *cross-plugin* mapping's tap into side effects,
whereas translation slices are *first-class components* for external integration.

### Directives relate to *outbound*, not inbound

The two translation directions line up with mappings like this:

| Direction | External seam (translation slice) | Cross-plugin seam (EP/Extension mapping) |
|---|---|---|
| **In** (something → domain command) | `InboundTranslationSlice`: external input → command (validated, audited) | `mapIncomingCommand` / `mapIncomingEvent`: foreign command/event → local command — **stays in-system** |
| **Out** (domain → effect) | `OutboundTranslationSlice`: event → external call (+ optional command back) | `mapOutgoingEvent` → `PublishEvent` (in-system) **or** `HandleDirective` (escapes to a side effect) |

A directive is essentially the **fire-and-forget cousin of an outbound
translation**, raised from within a cross-plugin mapping instead of being its own
component. There is no "inbound directive": inbound translation brings external
data *in as commands*, and the cross-plugin inbound analog (`mapIncomingCommand`)
is command-to-command and never leaves the event-sourced flow.

### The real difference is durability

Compared against the dedicated outbound-effect components —
[OutboundTranslationSlice](../components/outboundtranslationslice.md) (DCB plugins)
and [SideEffectHandler](../components/sideeffecthandler.md) (aggregate plugins):

| | `HandleDirective` (directive) | `SideEffectHandler` | `OutboundTranslationSlice` |
|---|---|---|---|
| What it is | an *action* returned by a cross-plugin mapping | a first-class *component* in a plugin | a first-class *component* in a plugin |
| Architecture | EP / Extension boundary (any) | aggregate-based plugins | DCB-based plugins |
| Triggered by | translating a cross-plugin event/command | the plugin's own event topics | the plugin's own DcbEventLog events |
| Tracking | none | none — fire-and-forget | TODO list with status (Pending/Processing/Completed/Failed) |
| Retry | none | EventCollector batch retry | per-item retry, configurable max |
| Idempotency | none | none (replays re-call) | dedup key prevents double-processing |
| Audit / observability | a log line only | none | QueryDb stores full history |
| Replay | never | never | re-derived from events |
| Schedule access | ✅ EP side only | ✅ | ✅ |
| Emits a command back | no | no | optional |

`SideEffectHandler` is the closest analog **in spirit**: both are unaudited,
untracked, fire-and-forget side effects. A directive is essentially a
SideEffectHandler-style effect expressed *inline* in a cross-plugin mapping rather
than as its own component — and it is the only one of the three that fires from a
**cross-plugin boundary** rather than from a plugin's own event stream.

### How to choose — or combine

- **Need a tracked, retryable, idempotent, observable external call** (the usual
  case for real integrations) → do **not** use a directive. Map the cross-plugin
  event to a **local command** (`PublishStateChangeSliceCommand` /
  `PublishAggregateCommand`), let it append an event, and let an
  `OutboundTranslationSlice` (DCB) or `SideEffectHandler` (aggregate) own the
  external call. The idiomatic chain is:
  `Extension → command → event → OutboundTranslationSlice → external`.
- **Need a lightweight, one-off effect at the boundary** where you accept no
  durability (a notification, a metric, an EP-side schedule) → a **directive** is
  the shortcut that skips that machinery.

In short: directives and translation slices both implement the
Translation / anti-corruption pattern, but a directive is the *cross-plugin
mapping's lightweight outbound side-effect hook*, while translation slices and
side-effect handlers are *dedicated components for external integration* with the
durability, retry, and observability a directive deliberately omits.

---

## Runtime semantics

- **Fire-and-forget.** A directive handler returns `promise<unit>`. Nothing
  consumes its result.
- **No event-sourcing guarantees.** A directive is not encoded to the event log,
  not published to a topic, not projected, and not replayed. It does not appear in
  any read model. If you need durability, use a command/event instead.
- **Errors are logged, not retried.** A throwing handler is caught and logged
  (`Error on handling directive: …`); the surrounding command/event processing
  continues.
- **Separate channel.** Directives are dispatched alongside the publish actions of
  the same mapping run, but on their own channel — an arm can both publish an event
  *and* handle a directive in the same step.

---

## Testing directives

The boundary GWT driver (`Delegate_GWT`, used by `*_ExtensionPointMapping_GWT.res`
and `*_Extension_GWT.res`) asserts directives on a **separate channel** from
published events/commands. Both the `FromExtensionPoint` and `FromExtension`
adapters expose:

```rescript
->thenHandlesDirective(directive)        // exactly this directive was handled
->thenHandlesDirectives([d1, d2])        // this set of directives
->thenHandlesNoDirective                 // no directive was handled
```

Because the channels are disjoint, an arm that both publishes and handles is
asserted independently:

```rescript
test("ProductAdded handles the NotifyOps directive", () =>
  whenDelegateEvent(Delegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}))
  ->thenHandlesDirective(ExtensionPoint.NotifyOps({channel: "ops"}))
)

// the same input still publishes its event — the directive does not leak in:
test("ProductAdded still publishes only the Pinged event", () =>
  whenDelegateEvent(Delegate.ProductAdded({productId: "p1", name: "Book", price: 9.99}))
  ->thenPublishesEvent("p1", ExtensionPoint.Pinged({productId: "p1"}))
)
```

Worked examples for both adapters live in
`reventless/gwt/tests/DelegateGwtTest.res` ("…— directives").

---

## Authoring

The VS Code authoring surface (in the `reventless-tools` repo) scaffolds directives
for you. **New ExtensionPoint** has a "Protocol directives" section; the
ExtensionPoint context menu offers **Add Directive…**. When a protocol declares at
least one directive, the generated ExtensionPoint *and* Extension mappings include
the matching `handleDirective` stub, and the generated GWTs include a
`thenHandlesNoDirective` starter test you flip to `thenHandlesDirective(…)` once an
arm wires one.

---

## See also

- [ExtensionPoint component](../components/extensionpoint.md)
- [Extension component](../components/extension.md)
- [Aggregate-Extension Connection](./aggregate-extension-connection.md)
- [OutboundTranslationSlice component](../components/outboundtranslationslice.md)
- [InboundTranslationSlice component](../components/inboundtranslationslice.md)
- [SideEffectHandler component](../components/sideeffecthandler.md)
- [Scheduler component](/framework/runtime-components/scheduler)
- [AutomationSlice component](../components/automationslice.md)
