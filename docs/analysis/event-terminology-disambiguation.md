# Event Terminology Disambiguation

## Problem Statement

The term "event" is overloaded across the codebase with at least three distinct meanings, and "handler" compounds the confusion by appearing in both domain and platform contexts.

## Current Usage Map

### Meaning 1: Domain Events (Event Sourcing)

These are **business facts** — things that happened in the domain (e.g., `ItemCreated`, `QuantityAdjusted`).

| Current Name | Type Signature | Location |
|---|---|---|
| `event` | `@schema type event` | `Aggregate.Spec`, `EventLog.T`, `EventTopic.T` |
| `event'` | `{id: 'id, meta: meta, event: 'event}` | `Message.res` (envelope) |
| `eventsHandler` | `('id, array<event'<'id, 'event>>) => promise<unit>` | `Handler.res` |
| `jsonEventsHandler` | `Stream.t<JSON.t, ...> => Effect.t<...>` | `EventCollector.res`, `Counter.res` |
| `jsonEventsHandler` | `(JSON.t, pluginDefinition) => promise<unit>` | `Plugin_Callback.res`, `Extension.res`, `ExtensionPoint.res` |
| `EventLog` | Component storing domain events | `EventLog/` |
| `EventTopic` | Component publishing domain events | `EventTopic/` |
| `EventCollector` | Component consuming domain events for projections | `EventCollector/` |
| `EventMapper` | Component routing domain events to commands | `EventMapper/` |
| `EventMapping` | Spec for event-to-command mapping | `EventMapping.res` |

### Meaning 2: Platform/Infrastructure Invocation Payloads

These are **runtime trigger payloads** — the data structure a Lambda function receives when invoked by SQS, SNS, API Gateway, etc.

| Current Name | Type Signature | Location |
|---|---|---|
| `event` | `{records: array<record>}` | `PulumiAws.Lambda.CallbackFunction` |
| `event` | alias of Lambda event | `RuntimeEnvironment_Lambda.res` |
| `event` | `JSON.t` | `RuntimeEnvironment_InMemory.res` |
| `eventHandler` | `('event, 'context) => promise<'result>` | `Runtime.res` |
| `effectHandler` | `('event, 'context) => Effect.t<'result, 'error, unit>` | `Runtime.res` |
| `eventHandler` | `eventHandler<event, unit>` | `PulumiAws.Lambda` |

### Meaning 3: Bus/Channel Messages (In-Memory Platform)

In the in-memory platform, messages flowing through the bus are sometimes called "events" even when they carry commands.

| Current Name | Type Signature | Location |
|---|---|---|
| `handler` | `(JSON.t, unit) => promise<unit>` | `RuntimeEnvironment_InMemory.res` |
| `enqueueEvent` | `(int, string, string) => promise<unit>` | `EventCollector.res` |

## Where Confusion Manifests

### 1. `eventHandler` means opposite things

- **`Runtime.eventHandler<'event, 'context, 'result>`** — handles platform invocations (Lambda payloads). Has nothing to do with domain events.
- **`Handler.eventsHandler<'id, 'event>`** — handles domain events in batch. The actual domain event handler.

A developer reading `eventHandler` in the runtime layer would naturally think it handles domain events. It doesn't.

### 2. `event` type parameter in runtime is not a domain event

```rescript
type eventHandler<'event, 'context, 'result> = ('event, 'context) => promise<'result>
```

The `'event` here is a Lambda Records payload or JSON blob — **not** a domain event. The generic name makes this invisible.

### 3. `jsonEventsHandler` has two incompatible signatures

- **Stream-based** in EventCollector/Counter: `Stream.t<JSON.t, ...> => Effect.t<...>`
- **Callback-based** in Plugin/Extension: `(JSON.t, pluginDefinition) => promise<unit>`

Same name, different shapes, different contexts.

### 4. `handleChannelEvent` bridges the gap invisibly

The adapter function `handleChannelEvent` converts a domain-level `jsonCommandsHandler` into a platform-level `effectHandler`. This is the actual boundary between the two "event" worlds, but its name doesn't communicate that.

## Proposal: Rename Platform Events to "Invocations"

### Core Principle

- **"Event"** should exclusively mean **domain event** (the event-sourced business fact)
- **"Invocation"** (or **"trigger"**) should mean the platform payload that activates a runtime handler
- **"Handler"** alone is fine for domain handlers; platform handlers become **"dispatch"** or **"runtime callback"**

### Proposed Renames

#### Runtime Layer (Platform Side)

| Current | Proposed | Rationale |
|---|---|---|
| `Runtime.eventHandler<'event, 'context, 'result>` | `Runtime.invocationHandler<'payload, 'context, 'result>` | This handles Lambda invocations, not domain events |
| `Runtime.effectHandler<'event, ...>` | `Runtime.effectInvocationHandler<'payload, ...>` | Same — Effect-based variant |
| `RuntimeEnvironment.event` | `RuntimeEnvironment.payload` | The Lambda/in-memory trigger payload |
| `PulumiAws.Lambda.event` | `PulumiAws.Lambda.invocationPayload` (or keep `event` since it's AWS's term) | AWS calls it "event" — we can keep it at the binding layer but alias it at the adapter |
| `runEffectHandler` | `runEffectInvocation` | Bridges Effect invocation to Promise |
| `aggregateHandler` | `aggregateDispatch` | Dispatches invocations to the right component handler |

#### Handler Registration (Runtime Builder)

| Current | Proposed | Rationale |
|---|---|---|
| `commandTopicHandlers` dict | `commandTopicDispatchers` | These are dispatch entries, not domain handlers |
| `eventCollectorHandlers` dict | `eventCollectorDispatchers` | Same |
| `commandGeneratorHandlers` dict | `commandGeneratorDispatchers` | Same |

#### Channel Adapter

| Current | Proposed | Rationale |
|---|---|---|
| `handleChannelEvent` | `wrapAsInvocationHandler` or `toInvocationHandler` | Makes the bridge role explicit |

#### Domain Layer (Keep "Event")

These names are **already correct** and should stay:

- `Message.event'<'id, 'event>` — domain event envelope
- `Handler.eventsHandler<'id, 'event>` — domain event handler
- `EventLog`, `EventTopic`, `EventCollector`, `EventMapper` — domain event infrastructure
- `@schema type event` in specs — domain event variants
- `jsonEventsHandler` (stream-based) — domain event JSON handler

#### Plugin/Extension Handlers

| Current | Proposed | Rationale |
|---|---|---|
| `jsonEventsHandler` (callback-based in Plugin/Extension) | `pluginEventCallback` or `crossPluginHandler` | Distinguishes from the stream-based `jsonEventsHandler` |

### Alternative: "Trigger" Instead of "Invocation"

If "invocation" feels too verbose:

| Current | Alternative |
|---|---|
| `Runtime.invocationHandler` | `Runtime.triggerHandler` |
| `RuntimeEnvironment.payload` | `RuntimeEnvironment.trigger` |
| `aggregateDispatch` | `aggregateTriggerHandler` |

"Trigger" is shorter but slightly less precise. "Invocation" maps directly to AWS Lambda terminology ("Lambda invocation").

### Alternative: "Request" Instead of "Invocation"

| Current | Alternative |
|---|---|
| `Runtime.invocationHandler` | `Runtime.requestHandler` |
| `RuntimeEnvironment.payload` | `RuntimeEnvironment.request` |

"Request" is HTTP-flavored and might cause confusion with API Gateway request types.

## Impact Assessment

### Files Requiring Changes

**High impact (type definitions):**
- `reventless-core/src/adapter/Runtime/Runtime.res` — core type renames
- `reventless-core/src/adapter/Runtime/AggregateRuntime_Builder_Common.res` — dispatch dict renames
- `reventless-in-memory/src/adapter/Runtime/RuntimeEnvironment_InMemory.res` — type alias
- `reventless-aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res` — type alias

**Medium impact (adapter implementations):**
- All `*_Adapter.res` files using `handleChannelEvent`
- All channel implementations (SQS, SNS, in-memory bus)
- Runtime builder variants (Single, PerAggregate, Micro)

**Low impact (no rename needed):**
- All spec types (`Handler.res`, `Message.res`, etc.) — already correct
- All component implementations (EventLog, EventTopic, etc.) — domain terms stay
- Example/test code — mostly uses domain terms

### Migration Strategy

1. **Phase 1**: Rename `RuntimeEnvironment.event` → `RuntimeEnvironment.payload` and add type alias `type event = payload` for backward compatibility
2. **Phase 2**: Rename `Runtime.eventHandler` → `Runtime.invocationHandler` with alias
3. **Phase 3**: Rename dispatch dicts and `handleChannelEvent`
4. **Phase 4**: Remove aliases after all consumers are updated
5. **Phase 5**: Update documentation

## Visual Summary

```
DOMAIN WORLD (keep "event")          PLATFORM WORLD (rename to "invocation")
─────────────────────────────        ─────────────────────────────────────────
  @schema type event                   RuntimeEnvironment.payload (was: event)
  Message.event'<'id, 'event>          Runtime.invocationHandler (was: eventHandler)
  Handler.eventsHandler                Runtime.effectInvocationHandler (was: effectHandler)
  EventLog / EventTopic                aggregateDispatch (was: aggregateHandler)
  EventCollector / EventMapper         commandTopicDispatchers (was: ...Handlers)
  jsonEventsHandler (stream)           wrapAsInvocationHandler (was: handleChannelEvent)
                    │                                  │
                    └──────── BRIDGE ──────────────────┘
                         Channel Adapter converts
                     domain handler → invocation handler
```

## Recommendation

Go with **"invocation"** for the platform side:
- It's AWS's own term for Lambda triggers
- It clearly separates from "event" (domain)
- The `'payload` type parameter reads naturally: `invocationHandler<'payload, 'context, 'result>`
- It doesn't collide with any existing terminology in the codebase

The `'event` type parameter in the runtime handler signature is the single biggest source of confusion — renaming it to `'payload` immediately clarifies that this is infrastructure plumbing, not domain logic.
