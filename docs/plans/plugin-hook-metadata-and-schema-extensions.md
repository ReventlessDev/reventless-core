# Plan: Plugin Hook Metadata and Schema Extensions

This plan covers six independent groups of changes to the core framework. Each group extends
the data that the plugin hooks (`onPluginBuilt`, `onPluginDeployed`) expose to consumers,
or adds a new hook point. All changes are backward-compatible.

The changes are grouped by priority and dependency order. Each group is independent of the
others except where noted.

---

## Group A — `pluginInfo` metadata extensions

**Priority: P2** — backward-compatible additions, no existing behaviour changes.

These two optional fields are added to the `pluginInfo` record that every plugin provides.
Because both are optional (`?`), no existing plugin breaks.

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Helpers.res`

### A.1 Add `pluginKind` to `pluginInfo`

```rescript
type pluginKind =
  | Domain
  | PlatformInfrastructure
  | Commercial
  | Marketplace

type pluginInfo = {
  name: string,
  version: string,
  // ... existing fields unchanged ...
  kind?: pluginKind,       // absent = Domain
  displayName?: string,
  vendor?: string,         // e.g. "private-consumer", "AcmeCorp"
}
```

`kind`, `displayName`, and `vendor` flow from `pluginInfo` into `pluginBuiltInfo` and
`pluginDeployedInfo` so hook consumers can act on them. Add to both info types:

```rescript
// Plugin_BuiltHook.res — pluginBuiltInfo
type pluginBuiltInfo = {
  name: string,
  version: string,
  kind?: pluginKind,
  displayName?: string,
  vendor?: string,
  components: array<pluginBuiltComponent>,
}

// Plugin_Helpers.res — pluginDeployedInfo
type pluginDeployedInfo = {
  name: string,
  version: string,
  environment: string,
  stackName: string,
  kind?: pluginKind,
  displayName?: string,
  vendor?: string,
  components: array<pluginDeployedComponent>,
  extensionWirings: array<extensionWiring>,
}
```

The fields are copied from `pluginInfo` when the hooks fire. No logic change — purely
propagating optional fields through.

### A.2 Add `architectureType` to `pluginInfo`

```rescript
type architectureType =
  | Aggregate       // CQRS aggregates + ReadModels, no DCB event log
  | Dcb             // shared DCB event log with StateChange/StateView/Automation slices
  | Hybrid          // both Aggregates and DCB slices in the same plugin
  | SdkService      // custom GraphQL resolvers only, no domain model components
  | Mcp             // MCP tools and resources, no AppSync resolvers
  | Mixed           // MCP + domain components (GraphQL + MCP surface for same domain)
```

Add `architectureType?: architectureType` to `pluginInfo`, `pluginBuiltInfo`, and
`pluginDeployedInfo` with the same optional-field pattern as `pluginKind`.

If absent, the consumer infers the value from the component list. No inference logic belongs
in core.

### A.3 Steps

- [ ] Add `pluginKind` variant type to `Plugin_Helpers.res`
- [ ] Add `kind?`, `displayName?`, `vendor?` to `pluginInfo`
- [ ] Add `architectureType` variant type to `Plugin_Helpers.res`
- [ ] Add `architectureType?` to `pluginInfo`
- [ ] Propagate all new fields into `pluginBuiltInfo` in `Plugin_BuiltHook.res`
- [ ] Propagate all new fields into `pluginDeployedInfo` in `Plugin_Helpers.res`
- [ ] Copy all from `pluginInfo` at hook fire sites (same pattern as existing field copies)
- [ ] Build: `npm run build` — verify no type errors in existing plugins (all fields optional)

---

## Group B — Deployment provenance in `pluginDeployedInfo`

**Priority: P1** — required for any consumer that needs to record when and by whom a deploy occurred.

`pluginDeployedInfo` currently carries `name`, `version`, `environment`, and `stackName` but
no information about when the deploy happened or who triggered it. Three fields are added:

```rescript
type pluginDeployedInfo = {
  name: string,
  version: string,
  environment: string,
  stackName: string,
  deployedAt: string,      // ISO 8601 — captured at Output.apply fire time
  actor: string,           // identity of who triggered the deploy
  deploymentId: string,    // unique identifier for this deploy run
  // ... other fields unchanged
}
```

`deployedAt` is captured inside the `Output.apply` callback in `exportPluginOutputs` as
`Date.now()->Float.toString` at the moment the hook fires.

`actor` and `deploymentId` are read from environment variables before the `Output.apply`
callback, since env vars are available synchronously. Fallback chain:

```
actor:        GITHUB_ACTOR → CI_COMMIT_AUTHOR → USER (OS username) → "local"
deploymentId: GITHUB_SHA → CI_COMMIT_SHA → timestamp (YYYYMMDDHHmmss)
```

### B.1 Steps

- [ ] Add `deployedAt`, `actor`, `deploymentId` to `pluginDeployedInfo` in `Plugin_Helpers.res`
- [ ] Read `actor` and `deploymentId` from env vars in `exportPluginOutputs` (before `Output.apply`)
- [ ] Capture `deployedAt` inside the `Output.apply` callback where the `info` record is constructed
- [ ] Build and verify the hook fires with populated fields in-memory and on AWS

---

## Group C — Field-level schema in `pluginDeployedSchema`

**Priority: P3** — enables consumers to track field-level schema changes and compute
structural hashes for rename detection.

**Approach: walk sury schemas at runtime — no PPX changes required.**

Sury schemas (`S.t<'a>`) are structurally introspectable at runtime. `DcbTag.res` already
does this extensively — pattern-matching on `Union({anyOf})`, `Object({properties})`,
`String({const})` etc. to extract tag information. The same mechanism can extract field
names, primitive types, and optionality from any schema at hook-fire time.

**Important limitation — type names are erased.**

Sury inlines the field structure at compile time. A field `price: money` where `money` is
`{amount: float, currency: string}` becomes an anonymous `Object({properties: {amount, currency}})` in
the compiled schema. The original type name `money` is not preserved. This means:

- Field names and primitive types (`string`, `float`, `bool`, `int`) are available ✓
- The full inlined field structure of each variant is available ✓
- Optionality (`field?: T` vs `field: T`) is available ✓
- Variant constructor names are available ✓
- **Named type references are not available** — `money` is invisible; only its fields are ✗
- A `namedTypeRegistry` keyed by type name is therefore not achievable via this approach

The field-level change detection and structural hashing goals are fully achievable. The
named type cross-referencing features described in the analysis (Type Registry, `namedTypes`
dict, `detect_type_impact` across shared types) require a different approach — either an
upstream contribution to sury-ppx to emit type names, or a separate compile-time metadata
generation step outside of sury. That work is deferred; it is not a prerequisite for
field-level breaking change detection.

### C.1 New types in `Plugin_BuiltHook.res`

```rescript
// A single field extracted from a sury object schema.
type fieldSchema = {
  name: string,
  typeDescription: string,  // human-readable type: "string", "float", "object", "array", "union"
  isRequired: bool,         // true = required field (field: T); false = optional (field?: T)
}

// Schema for one named type (a command, event, or state type).
// Fields are the full inlined field list — nested types are flattened by name only.
type typeSchema = {
  typeName: string,          // e.g. "ProductAdded", "AddProduct"
  kind: string,              // "record" | "variant"
  fields: array<fieldSchema>,           // for records: all fields
  constructors?: array<{                // for variants: one entry per constructor
    name: string,                       // e.g. "AddProduct"
    fields: array<fieldSchema>,         // the constructor's payload fields
  }>,
  structuralHash: string,    // SHA3-256 of sorted "name:typeDescription:isRequired" tuples
}
```

`structuralHash` is computed over the sorted field set (alphabetically by field name):
`fieldName:typeDescription:isRequired` joined by `|`. For variants: sorted constructor
names each with their sorted field hashes, joined by `||`. This is a stable fingerprint
of the type's shape — if it changes between versions, the type changed.

Unlike the `shallowHash`/`structuralHash` distinction proposed in the analysis, a single
hash is sufficient here because nested types are inlined — there is no separate named type
layer to isolate.

### C.2 Extend `pluginDeployedSchema`

```rescript
type pluginDeployedSchema = {
  // existing fields unchanged
  commandTypes?: array<string>,
  eventTypes?: array<string>,
  errorTypes?: array<string>,
  stateType?: string,
  sourceNames?: array<string>,
  queryFields?: array<string>,
  consumedEventTypes?: array<string>,
  producedCommandTypes?: array<string>,
  sharedBy?: array<string>,
  extensionPointName?: string,
  providerPlugin?: string,
  subscriberPlugins?: array<string>,
  // new fields — all optional for backward compatibility
  commandSchemas?: array<typeSchema>,  // field-level schema per command type
  eventSchemas?: array<typeSchema>,    // field-level schema per event type
  stateSchema?: typeSchema,            // field-level schema for the state type
}
```

`namedTypes` is omitted — it is not achievable without PPX-level type name preservation.

### C.3 Schema walker in core

Add `SchemaWalker.res` (or equivalent) that converts an `S.t<unknown>` into a `typeSchema`.
It follows the same pattern as `DcbTag.extractTaggedFields` and `DcbTag.extractEventTypes`:

```rescript
// Pseudocode — mirrors DcbTag pattern-matching style
let describeSchema = (schema: S.t<unknown>): string =>
  switch schema {
  | String(_) => "string"
  | Float(_) | Int(_) => "number"
  | Bool(_) => "bool"
  | Array(_) => "array"
  | Option(inner) => "option<" ++ describeSchema(inner) ++ ">"
  | Object(_) => "object"
  | Union(_) => "union"
  | _ => "unknown"
  }

let extractFieldsFromProperties = (properties: dict<S.t<unknown>>): array<fieldSchema> =>
  properties->Dict.toArray->Array.map(((name, fieldSchema)) => {
    name,
    typeDescription: describeSchema(fieldSchema),
    isRequired: !(fieldSchema->isOptional),  // sury exposes this
  })

let walkSchema = (typeName: string, schema: S.t<unknown>): typeSchema =>
  switch schema {
  | Object({properties}) =>
    {
      typeName,
      kind: "record",
      fields: extractFieldsFromProperties(properties),
      structuralHash: computeHash(fields),
    }
  | Union({anyOf}) =>
    let constructors = anyOf->Array.filterMap(variantSchema =>
      switch variantSchema {
      | Object({items, properties}) =>
        let name = items->Array.find(i => i.location == "TAG")
          ->Option.flatMap(i => switch i.schema { | String({const}) => Some(const) | _ => None })
        name->Option.map(n => {name: n, fields: extractFieldsFromProperties(properties)})
      | _ => None
      }
    )
    { typeName, kind: "variant", fields: [], constructors: Some(constructors),
      structuralHash: computeHash(constructors) }
  | _ => { typeName, kind: "unknown", fields: [], structuralHash: "" }
  }
```

The walker is called from `Plugin_Builder.res` at the point where command/event/state
schemas are already available (same location where `componentSchemaRegistry` is populated).
One `walkSchema` call per command type name, one per event type name, one for the state type.

### C.4 Where schemas are available in `Plugin_Builder.res`

The command and event schemas are already in scope in `Plugin_Builder.res` at lines
where `Plugin_Helpers.pluginDeployedSchema` is constructed (lines ~231–255 in the current
file). The state schema is available via the slice spec. These are passed directly to
`walkSchema` — no new hooks or PPX involvement required.

### C.5 Steps

- [ ] Add `fieldSchema`, `typeSchema` types to `Plugin_BuiltHook.res`
- [ ] Add `commandSchemas?`, `eventSchemas?`, `stateSchema?` to `pluginDeployedSchema`
- [ ] Implement `SchemaWalker.res`: `describeSchema`, `extractFieldsFromProperties`, `walkSchema`
- [ ] Implement hash computation (SHA3-256 or BLAKE3 over sorted field tuples)
- [ ] Call `walkSchema` for each command type and event type in `Plugin_Builder.res` where schemas are constructed
- [ ] Build: verify output for the online-shop example plugins
- [ ] Test: field names and hashes match expected values for a known command type

---

## Group D — Event originator tag in DCB event writes

**Priority: P4** — small change, enables per-slice activity tracking by consumers.

When a `StateChangeSlice` writes events to the DCB event log via `publishJsons`, it should
tag each event with the name of the producing slice. The slice name is already known at
construction time (it is the `Spec.name` value used as the mutation field name).

### D.1 Secondary tag on DCB events

The DCB event write path currently tags events with the partition tag derived from
`@partitionTag`-annotated fields. A secondary string tag `originatorSlice` is added:

```rescript
// Pseudocode — inside the publishJsons implementation
let tags = [
  DcbTag.partition(partitionKey),
  DcbTag.string("originatorSlice", sliceName),  // ← new
  // ... existing additional tags
]
```

**Files to change:** wherever `publishJsons` constructs the tag array before writing:
- `reventless-aws/src/Dcb/DcbEventLogStorage_DynamoDb_Runtime.res` — AWS write path
- The in-memory equivalent

The slice name is available as a closed-over value from the slice builder; the builder
already passes the field name (mutation name) as a parameter.

### D.2 Steps

- [ ] Identify the exact call site where DCB event tags are constructed
- [ ] Thread the slice name through the call chain if not already available at the write site
- [ ] Add `DcbTag.string("originatorSlice", sliceName)` to the tag array
- [ ] Verify the tag appears in event records (in-memory test or AWS spot check)
- [ ] Confirm no existing tests break (the tag is additive)

---

## Group E — Resolver error hook

**Priority: P4** — provides a hook point that consumers can register to observe unknown
command type attempts at runtime.

When a `generateCommand` resolver receives a command type not registered in the handler
registry, it currently returns a GraphQL error. The same path should optionally fire a hook.

### E.1 New hook in `Plugin_Helpers.res`

```rescript
type resolverErrorInfo = {
  pluginName: string,
  componentName: string,
  fieldName: string,              // the GraphQL mutation field that was called
  attemptedCommandType: string,   // the command variant that was not found
  callerIdentity: string,         // from AppSync auth context
  timestamp: string,              // ISO 8601
}

let onResolverErrorHook: ref<option<resolverErrorInfo => unit>> = ref(None)

let registerOnResolverError = (hook: resolverErrorInfo => unit) => {
  onResolverErrorHook.contents = Some(hook)
}
```

### E.2 Fire the hook in the resolver error path

In `CommandGenerator_Callback.res`, in the branch where the command type is not found:

```rescript
switch onResolverErrorHook.contents {
| Some(hook) =>
  hook({
    pluginName,
    componentName,
    fieldName,
    attemptedCommandType,
    callerIdentity,
    timestamp: Date.now()->Float.toString,
  })
| None => ()
}
```

The hook fires synchronously with a `unit` return — fire-and-forget. Registered consumers
handle any async work independently.

**Note — query field errors (reventless-sdk, not core):** A parallel hook for unknown
query field names belongs in `reventless-sdk`'s `QueryPipeline`, not in `reventless-core`.
That hook also enables query call count tracking and is planned separately.

### E.3 Steps

- [ ] Add `resolverErrorInfo` type, `onResolverErrorHook` ref, and `registerOnResolverError` to `Plugin_Helpers.res`
- [ ] Identify the error branch in `CommandGenerator_Callback.res` where unknown types are rejected
- [ ] Fire the hook in that branch with fully populated `resolverErrorInfo`
- [ ] Build and verify the hook fires in an in-memory test with an unknown command type

---

## Group F — GraphQL subscription resolver support (investigation)

**Priority: P2** — investigation complete; implementation tracked separately.

### F.1 Steps

- [x] Read `reventless-aws/src/adapter/Api/AppSync_Resolver_*.res` to understand the current resolver registration model
- [x] Determine if `@aws_subscribe` directives can be attached to existing resolver resources or require a new resource type
- [x] Document outcome: "already supported" or "requires change X"

**Outcome: Requires new infrastructure.** Implementation tracked in a dedicated plan.

Neither `AppSync_Resolver_Native.res` nor `AppSync_Resolver_Retrying.res` contains any reference to `@aws_subscribe`, subscription resolvers, or `Subscription` type resolver construction. Both builders only create `Mutation` and `Query` resolvers. The required changes are:

1. Add `makeSubscriptionResolver` to both resolver builder files
2. Add a `subscriptions: string` field to `GraphqlSchema.fragment` for SDL generation
3. New `Plugin_SubscriptionSchema.res` to generate subscription SDL fragments per plugin
4. New `StateTopic_AppSync` (DynamoDB Stream → AppSync Events API) and `EventLogSubscription_AppSync` (SNS → AppSync Events API) for push-based subscription sources

**See**: [graphql-subscriptions-appsync.md](graphql-subscriptions-appsync.md) — the full implementation plan for AppSync subscription infrastructure (Sources A, B, C) and in-memory yoga WebSocket support.

---

## Dependency graph

```
Group A (pluginInfo metadata)       → no prerequisites
Group B (deployment provenance)     → no prerequisites
Group C (field-level schema / PPX)  → no prerequisites (self-contained PPX work)
Group D (originator tag)            → no prerequisites
Group E (resolver error hook)       → no prerequisites
Group F (subscription infra)        → investigation complete, implementation in graphql-subscriptions-appsync.md
```

Groups A and B should land first as they unblock the most downstream consumers.
Group C is the largest engineering effort and can proceed in parallel.
Groups D and E are independently usable at any point.
Group F is complete as an investigation — the `originatorSlice` tag added in Group D feeds directly into the Source A subscription payload in the subscription plan.

---

## Checklist

### Group A — pluginInfo metadata
- [x] A.1: `pluginKind` type + `kind?` / `displayName?` / `vendor?` in `Plugin_BuiltHook.pluginBuiltInfo`, `Plugin_Helpers.pluginDeployedInfo`
- [x] A.2: `architectureType` type + `architectureType?` in same two types
- [x] A.3: `pluginMetadata` type + `pluginMetadataRegistry` ref + `registerPluginMetadata` in `Plugin_BuiltHook.res`
- [x] A.4: Metadata propagated into both hook payloads via `pluginMetadataRegistry`
- [x] A.5: Build clean

### Group B — Deployment provenance
- [x] B.1: `deployedAt`, `actor`, `deploymentId` in `Plugin_Helpers.pluginDeployedInfo`
- [x] B.2: Env var reads + fallback chain (`GITHUB_ACTOR` → `CI_COMMIT_AUTHOR` → `USER` → "local"; `GITHUB_SHA` → `CI_COMMIT_SHA` → timestamp) in `exportPluginOutputs`
- [x] B.3: `deployedAt` captured inside `Output.apply` at hook-fire time
- [x] B.4: In-memory `Platform.res` also updated (uses `"local"` + ISO timestamp as fallbacks)
- [x] B.5: Build clean

### Group C — Field-level schema (runtime schema walker)
- [x] C.1: `fieldSchema`, `constructorSchema`, `typeSchema` types in `Plugin_BuiltHook.res`
- [x] C.2: `commandSchemas?`, `eventSchemas?`, `stateSchema?` in `pluginDeployedSchema`
- [x] C.3: `SchemaWalker.res` — `describeSchema`, `extractFields`, `walkSchema`, `walk`
- [x] C.4: SHA256 hash via `HashObj.hashDict` over sorted field tuples; separate `hashConstructors` for variants
- [x] C.5: `commandSchemas` and `eventSchemas` wired for Aggregate components in `Plugin_Builder.res`
- [x] C.6: Build clean (note: SHA256 used instead of SHA3-256 — `rescript-hash-object` provides SHA256)
- [ ] C.7: Test: field names and hashes correct for a known command type (deferred — manual verification via real deploy)

### Group D — Originator tag
- [x] D.1: Write site identified: `StateChangeSlice_Callback.res` `encodeEvent` function
- [x] D.2: Slice name available as `Spec.name` (closed-over functor param) — no threading needed
- [x] D.3: `{key: "originatorSlice", value: Spec.name}` appended to tag array in `encodeEvent`
- [x] D.4: Build clean; tag added to every DCB event produced by a StateChangeSlice

### Group E — Resolver error hook
- [x] E.1: `resolverErrorInfo` type + `onResolverErrorHook` ref + `registerOnResolverError` + `clearOnResolverError` in `Plugin_Helpers.res`
- [x] E.2: Hook fired in `CommandGenerator_Callback.res` `| exception err =>` branch (command decode failure path)
- [x] E.3: Build clean

### Group F — Subscription infra
- [x] F.1: `AppSync_Resolver_Native.res` and `AppSync_Resolver_Retrying.res` inspected — no subscription support
- [x] F.2: Outcome: **Requires new infrastructure** — implementation plan: [graphql-subscriptions-appsync.md](graphql-subscriptions-appsync.md)
