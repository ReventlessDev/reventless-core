# Callback Hooks and Adapter Wrapping

The framework provides optional callback hooks at key processing boundaries and exposes adapter operations as plain records. Together, these allow external code to intercept, observe, or transform framework behavior without modifying the core.

---

## Callback Hooks

Four module-level hooks are available, each a `ref<option<callback>>`. When `None` (the default), the framework passes through unchanged. When set to `Some(fn)`, the function runs as part of the normal processing flow.

### Command Interceptor

**Module:** `CommandGenerator_Callback`

```rescript
type interceptResult = Allow | Deny(string)

type commandInterceptor = (
  ~identity: Reventless.Identity.t,
  ~componentName: string,
  ~componentKind: commandComponentKind,
  ~tag: string,
  ~args: JSON.t,
) => promise<interceptResult>

let registerCommandInterceptor: commandInterceptor => unit
let clearCommandInterceptor: unit => unit
```

Called before every command is dispatched to an aggregate or state change slice. Receives the caller's identity, the target component, and the command payload. Returns `Allow` to proceed or `Deny(reason)` to reject the command before it reaches the `decide` function.

**Where it fires:** `CommandGenerator_Callback.makeGenerateCommand` — the function that every command generator resolver calls when a GraphQL mutation arrives.

**Use cases:** authentication, authorization, rate limiting, tenant scoping, audit logging, command validation.

### Query Interceptor

**Module:** `QueryDb_Callback`

```rescript
type interceptResult = Allow | Deny(string)

type queryInterceptor = (
  ~identity: Reventless.Identity.t,
  ~readModelName: string,
  ~args: JSON.t,
) => promise<interceptResult>

let registerQueryInterceptor: queryInterceptor => unit
let clearQueryInterceptor: unit => unit
```

Called before every read model query is executed. Receives the caller's identity, the read model name, and the query arguments. Returns `Allow` to proceed or `Deny(reason)` to reject.

**Where it fires:** The query resolver path in `QueryDb` operations, before the read model store is accessed.

**Use cases:** query authorization, tenant-scoped access control, query logging.

### Event Publish Hooks

**Module:** `EventPublish_Callback`

```rescript
type publishedEvent = {
  componentName: string,
  entityId: string,
  eventCount: int,
  eventsJson: array<JSON.t>,
  meta: Reventless.Message.meta,
}

type beforePublishHook = publishedEvent => promise<publishedEvent>
type afterPublishHook = publishedEvent => promise<unit>

let registerBeforePublish: beforePublishHook => unit
let registerAfterPublish: afterPublishHook => unit
let clearPublishHooks: unit => unit
```

**`beforePublishHook`** — Called before events are written to the EventTopic. Receives the event batch and returns a (possibly transformed) batch. Can modify event payloads, add metadata, or filter events.

**`afterPublishHook`** — Called after events are published. Observe-only — the return value is ignored. Fires even if publication encountered errors (the hook receives whatever was published).

**Where they fire:** `EventLog_Operations.append`, `DcbEventLog_Operations.append`, and `ExtensionPoint_Operations` — every component that publishes events. This means hooks see events from aggregates, DCB state change slices, and extension points uniformly.

**Use cases:**
- `beforePublishHook`: event enrichment (add tenant ID, correlation ID), crypto-shredding (encrypt PII fields before storage), event filtering
- `afterPublishHook`: event counting, latency metrics, audit trail recording, notification triggers

---

## Why One Hook Per Concern

Each hook is a single `ref<option<callback>>`, not a list. This is deliberate:

1. **The core doesn't need multiplexing.** A user who just wants to log commands doesn't need a middleware chain. They set the hook to their function and it works.

2. **Composition belongs outside the core.** If you need multiple handlers for the same hook (authentication *and* rate limiting *and* logging on commands), you compose them into a single function before setting the hook. This keeps the core simple — it calls one function, not a list.

3. **External packages can provide the composition layer.** A middleware pipeline that composes multiple handlers into one, sorts by priority, and isolates errors is valuable — but it's an opinion about how composition should work. The core provides the interception point; the composition strategy is up to the consumer.

```rescript
// Simple: register a single function
CommandGenerator_Callback.registerCommandInterceptor(myAuthCheck)

// Composed: register a function that runs multiple checks
let composed = async (~identity, ~componentName, ~componentKind, ~tag, ~args) => {
  let authResult = await checkAuth(~identity, ~componentName, ~componentKind, ~tag, ~args)
  switch authResult {
  | Deny(_) as d => d
  | Allow => await checkRateLimit(~identity, ~componentName, ~componentKind, ~tag, ~args)
  }
}
CommandGenerator_Callback.registerCommandInterceptor(composed)
```

---

## Adapter Operation Records

Every component exposes its runtime operations as a plain record type. For example:

```rescript
// DcbEventLog
type operations = {
  read: read,
  append: append,
  readStream: readStream,
  appendStream: appendStream,
}

// Aggregate
type operations = {
  publishJsons: CommandTopic.publishJsons,
  publishJsonsStream: CommandTopic.publishJsonsStream,
}
```

These records are obtained at runtime via `Component.operations(myComponent)` and are what Lambda handlers use to interact with the infrastructure.

### Wrapping with the Decorator Pattern

Because operations are plain records of functions, you can wrap them by creating a new record that delegates to the original:

```rescript
let original: DcbEventLog.operations = Component.operations(myDcbEventLog)

let wrapped: DcbEventLog.operations = {
  read: original.read,
  append: async (id, events, meta) => {
    Console.log(`Appending ${events->Array.length->Int.toString} events to ${id}`)
    await original.append(id, events, meta)
  },
  readStream: original.readStream,
  appendStream: original.appendStream,
}
```

This is the standard decorator pattern — no framework support needed, just record spread and function wrapping. You can intercept any operation, add logging, transform arguments, modify return values, or short-circuit entirely.

### ID and Key Transformation

The same pattern supports remapping identifiers before they reach storage:

```rescript
let tenantScoped: DcbEventLog.operations = {
  ...original,
  read: (id, filter) => original.read(tenantId ++ ":" ++ id, filter),
  append: (id, events, meta) => original.append(tenantId ++ ":" ++ id, events, meta),
}
```

Every read and write to this event log now operates in a tenant-specific namespace, transparent to the business logic above.

### Storage-Level Wrapping

For deploy-time composition, adapters expose a `storage` type that wraps `operations` inside a `Pulumi.Output.t`. Wrapping at this level applies the decoration when the Pulumi Output resolves — before the Lambda handler receives the operations record:

```rescript
type storage = {
  operations: Pulumi.Output.t<operations>,
}
```

This means the wrapping is configured at deploy time (in the Pulumi stack) but executes at runtime (inside the Lambda). The Lambda handler receives an already-wrapped operations record and doesn't know or care that wrapping was applied.

---

## Processing Flow

```
Command arrives (GraphQL mutation)
  |
  v
CommandGenerator_Callback
  |-- commandInterceptorHook -> Allow / Deny
  |
  v (if Allow)
Aggregate.decide / StateChangeSlice.decide
  |
  v (events produced)
EventLog_Operations.append / DcbEventLog_Operations.append
  |-- beforePublishHook -> transform events
  |-- write to EventLog / DcbEventLog
  |-- publish to EventTopic
  |-- afterPublishHook -> observe events
  |
  v
Query arrives (GraphQL query)
  |
  v
QueryDb_Callback
  |-- queryInterceptorHook -> Allow / Deny
  |
  v (if Allow)
ReadModel query execution
```

Each hook is optional. When unset, the arrow passes straight through. When set, external code runs at that boundary — with full access to the identity, component context, and payload — and decides whether to allow, deny, transform, or observe.
