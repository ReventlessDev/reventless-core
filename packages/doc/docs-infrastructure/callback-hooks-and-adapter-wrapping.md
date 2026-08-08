# Callback Hooks and Adapter Wrapping

The framework provides optional callback hooks at key processing boundaries and exposes adapter operations as plain records. Together, these allow external code to intercept, observe, or transform framework behavior without modifying the core.

---

## Callback Hooks

Five module-level hooks are available, each a `ref<option<callback>>`. When `None` (the default), the framework passes through unchanged. When set to `Some(fn)`, the function runs as part of the normal processing flow.

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

### Plugin Built

**Module:** `Plugin_Helpers`

```rescript
type pluginBuiltComponent = { name: string, kind: string }
type pluginBuiltInfo = { name: string, version: string, components: array<pluginBuiltComponent> }

let registerOnPluginBuilt: (pluginBuiltInfo => unit) => unit
let clearOnPluginBuilt: unit => unit
```

Called after a plugin's components are fully constructed. Receives the plugin name, version, and a list of all component names and kinds. Fires synchronously during `Plugin_Builder.construct`, before `makePlatform` or `deployPlugin` returns.

**Where it fires:** `Plugin_Builder.construct` — after all component builders have run and the component dicts are populated, before the `Output.apply` block.

**Use cases:** plugin metadata registration, deploy-time metadata persistence, admin dashboard population.

---

## Registering Hooks in a Deployed Runtime

The four runtime hooks above are module-level `ref`s. They only do anything if something calls the registrar **in the same process, before the first request**. In your deploy program that is easy; inside a deployed Lambda it is not — the handler is a framework-owned entry shell that imports framework and domain modules only, so an out-of-tree package has nowhere to put its registration.

`RuntimeExtension` is the way in. It fires once per runtime process, before that runtime handles its first request.

**Module:** `ReventlessCore.RuntimeExtension`

```rescript
type coldStartHook = (
  ~runtimeKind: ComponentType.t,
  ~component: string,
  ~plugin: option<string>,
  ~platform: option<string>,
) => unit

module type Extension = {
  let moduleUrl: string
  let onColdStart: coldStartHook
}

let use: module(Extension) => unit
```

Write the extension in its own package and register it in the deploy program, before the platform builds:

```rescript
// @acme/tracing/src/TracingExtension.res
module Ext: ReventlessCore.RuntimeExtension.Extension = {
  let moduleUrl: string = %raw(`import.meta.url`)

  let onColdStart = (~runtimeKind as _, ~component, ~plugin, ~platform as _) =>
    ReventlessCore.CommandGenerator_Callback.registerCommandInterceptor(async (
      ~identity,
      ~componentName,
      ~componentKind as _,
      ~tag,
      ~args as _,
    ) => {
      Trace.record(~runtime=component, ~plugin, ~componentName, ~tag, ~user=identity.userId)
      Allow
    })
}
```

```rescript
// Main.res — the deploy program, before makePlatform / deployPlugin
ReventlessCore.RuntimeExtension.use(module(TracingExtension.Ext: ReventlessCore.RuntimeExtension.Extension))
```

That single registration covers both platforms:

- **AWS** — the framework bundles the extension's package into every runtime's code archive and names the module in a `RUNTIME_EXTENSIONS` env var. Each entry shell imports it and calls `onColdStart` before it builds a handler. This is why `moduleUrl` is part of the module type: registering a first-class module only populates the deploy program's process, and the Lambda is a different one.
- **reventless-local** — everything runs in one process, so the seam fires once at platform startup with `runtimeKind: Platform` and `component: "LocalPlatform"`. Off Lambda there is one cold start, not one per runtime.

Notes:

- `~component` is the runtime's logical name. A shared Lambda hosts several components of one kind (`AllAggregatesCmdHandler`), so use the per-request `~componentName` on the interception hooks to tell them apart.
- `~plugin` / `~platform` come from the same attribution context the resource tags use, and are `None` for platform substrate.
- `onColdStart` is **synchronous**. An awaited hook would put extension latency on every cold path. Start I/O here if you need it; don't block on it.
- Several extensions compose, and run in registration order.
- A throwing extension is logged at ERROR and skipped — the runtime still serves, and its siblings still run.
- Registering nothing costs nothing: no package is bundled, no env var is set, and the code archive is byte-identical.

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
Plugin_Builder.construct
  |
  v
Plugin_Helpers
  |-- onPluginBuiltHook -> observe plugin metadata
  |
  v
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
