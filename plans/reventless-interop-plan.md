# Plan: `reventless-interop` — Versioned Cross-Plugin Contract Package

## Problem Statement

When multiple plugin stacks are deployed independently, they exchange data through Pulumi stack
references. Stack A exports its outputs as serialized JSON; Stack B reads them and casts the result
to a typed record:

```rescript
// Current Interstack.res
let stackDependenciesTasks: Pulumi.Output.t<array<Task.outputs>> = getOutputs("tasks")
```

This cast is **unchecked**. If Stack A and Stack B are deployed with different versions of the
framework, and `Task.outputs` changed between those versions, Stack B silently deserializes wrong
data at deploy time — no compile error, no runtime exception, just incorrect infrastructure.

The same problem exists in the **runtime message protocol** between extensions and extension points.
When Plugin B's extension sends commands to Plugin A's extension point, messages are encoded with
`@schema`-generated JSON codecs. If the `command` or `event` type changes between versions of the
two plugins, messages can fail to decode silently.

---

## Terminology

| Term | Meaning | Replaces |
|------|---------|---------|
| `outputs` | Deploy-time output type containing `Pulumi.Output.t<X>` fields | unchanged |
| `resolvedOutputs` | Same record with every `Pulumi.Output.t<X>` replaced by plain `X`, because Pulumi resolves all pending values before serializing stack exports | `Plugin_Helpers.pureOutputs` (has TODO "find better naming"), `ExtensionPoint.unwrappedOutputs`, `CommandTopic.unwrappedOutputs`, `EventTopic.unwrappedOutputs` |
| `directive` | An internal orchestration instruction that the framework executes as a side effect of processing a command or event; neither a domain command sent externally nor a domain event | `callCommand` in `ExtensionPoint.Spec`, `ExtensionMapping.Spec`, `ExtensionPointMapping.Spec` |
| field manifest | The list of field names that are actually present in a given stack export, derived automatically at deploy time | — |

**`pureOutputs` and `unwrappedOutputs`** are the same concept with two names. The interop package
settles on `resolvedOutputs`, and the existing uses in `reventless` are migrated to it.

**URNs, not ARNs.** All references to resource identifiers in this plan use the provider-agnostic
term URN (Uniform Resource Name). AWS ARNs are one implementation.

---

## Two Versioning Concerns

### 1. Infrastructure versioning (deploy-time, cross-stack)

When Plugin B reads Plugin A's task bucket URNs or QueryDb resources, it reads Pulumi stack
exports as `resolvedOutputs` records. If the shape of those records changes between interop
versions, the deserialization is wrong.

**Solution:** a projection API — Plugin B declares exactly which fields it needs from Plugin A's
exports. The interop package validates at deploy time that those fields are present.

### 2. Protocol versioning (runtime, cross-plugin)

When Plugin B's extension sends a `command` to Plugin A's extension point, the message is encoded
using `@schema`-derived codecs. If the `command` or `event` variants change between plugin
versions, the codec mismatches silently.

**Solution:** protocol version declarations in the `ConnectPlugin` handshake, plus an
additive-only evolution policy for `@schema` message types.

---

## What Actually Crosses Stack Boundaries

Only three things are named Pulumi stack exports today:

| Export name | Type | Current form | Used for |
|-------------|------|-------------|---------|
| `"tasks"` | `array<Task.outputs>` | unchecked cast in `Interstack` | S3 bucket URNs for cross-plugin task data |
| `"eventMappers"` | `array<EventMapper.outputs>` | unchecked cast in `Interstack` | Event source routing across plugins |
| `"plugin"` | `Plugin.pureOutputs` | unchecked cast in `Plugin_Helpers` | Remote QueryDb resources; extension point topic URNs |

The interop package therefore defines `resolvedOutputs` for exactly these three. All other
component output types (`Aggregate`, `ReadModel`, `Heartbeat`, etc.) only appear as sub-types
within `Plugin.resolvedOutputs` when consumed via its projection — they are not separately exported
and do not require their own top-level interop entry.

Sub-types needed for navigating a `Plugin.resolvedOutputs` projection:

- `ReadModel.resolvedOutputs` — accessed to get `queryDb.resources`
- `ExtensionPoint.resolvedOutputs` — accessed to get topic URNs for extension connections
- `CommandTopic.resolvedOutputs` — URN payload within `ExtensionPoint.resolvedOutputs`
- `EventTopic.resolvedOutputs` — URN payload within `ExtensionPoint.resolvedOutputs`
- `EventCollector.resolvedOutputs` — if needed by consumers

These sub-types live in the interop package as supporting definitions, not as separate query
targets.

---

## Proposed Solution: `reventless-interop` Package

A new Lerna package (`packages/reventless-interop`) that owns:

1. **Resolved output types** — `Output.t`-free, JSON-serializable counterparts of the three
   exported output types and their necessary sub-types
2. **Stack export metadata** — the interop version and field manifest written alongside exports
3. **Projection API** — consumers declare exactly which fields they need; the interop package
   validates compatibility and extracts only those fields
4. **Query engine** — replaces `Interstack.getOutputs` with typed, validated queries
5. **Protocol version types** — version declarations for extension point message schemas
6. **Connection handshake extensions** — protocol version negotiation at `ConnectPlugin` time

This package is versioned on its own SemVer axis, independently of `reventless-spec` and
`reventless`.

---

## Part 1: Infrastructure Versioning

### Resolved output types

**Transformation rule:** `Pulumi.Output.t<X>` → `X`. Every other field is identical.

```rescript
// reventless-interop/src/components/Task.res
@schema
type resolvedOutputs = {
  name: string,
  bucketNames?: dict<string>,        // was dict<Pulumi.Output.t<string>>
  sideEffectSources?: array<string>,
}

// reventless-interop/src/components/EventMapper.res
@schema
type resolvedOutputs = {
  name: string,
  eventCollector: EventCollector.resolvedOutputs,
  counter?: Counter.resolvedOutputs,
}

// reventless-interop/src/components/Plugin.res
// Only the fields that are actually accessed cross-stack are required;
// others are optional so old publishers without those fields still validate.
@schema
type resolvedOutputs = {
  id: string,
  version: string,
  readModels?: dict<ReadModel.resolvedOutputs>,
  extensionPoints?: dict<ExtensionPoint.resolvedOutputs>,
  // Other plugin fields omitted — consumers project only what they need
}

// reventless-interop/src/components/ExtensionPoint.res
// Sub-type of Plugin.resolvedOutputs; not a separate stack export
@schema
type resolvedOutputs = {
  name: string,
  commandTopic: CommandTopic.resolvedOutputs,  // URN
  eventTopic: EventTopic.resolvedOutputs,      // URN
}
```

The `@schema` attribute causes sury-ppx to generate a `resolvedOutputsSchema: S.t<resolvedOutputs>`
value for each type, used by the query engine for both parsing and serialization.

### Field manifest — automatic, no manual maintenance

The field manifest is derived **automatically at deploy time** from the actual JSON produced by
the `@schema` encoder — not from a hardcoded registry. When `Plugin_Builder` serializes its
outputs, the interop export helper encodes the `resolvedOutputs` record and extracts the resulting
JSON object's keys:

```rescript
// reventless-interop/src/ExportMeta.res
let fieldNamesOf = (value: 'a, schema: S.t<'a>): array<string> =>
  value
  ->S.reverseConvertToJsonOrThrow(schema)
  ->Js.Json.decodeObject
  ->Option.mapOr([], Js.Dict.keys)
```

**Consequences:**
- Required fields always appear in the manifest (because the encoder always emits them)
- Optional fields appear only when they have a value — a consumer that requires an optional field
  gets a compatibility error when it is absent from a specific publisher's output
- Adding a field to `resolvedOutputs` automatically makes it appear in the next deployment's
  manifest — no list to update
- Removing a field makes it disappear from the manifest in the next deployment — this is a MAJOR
  version bump per the SemVer policy below

Developers maintain exactly one thing: the SemVer of the `reventless-interop` package itself,
following this policy:

| Change | Version bump |
|--------|-------------|
| Add a new optional field | MINOR |
| Make a required field optional | MINOR |
| Bug fixes, no type changes | PATCH |
| Remove a field (after deprecation window) | MAJOR |
| Rename a field | MAJOR |
| Add a required field | MAJOR |

**Deprecation window**: Fields scheduled for removal are marked deprecated at vX.0 and removed no
sooner than v(X+1).0. During the window, publishers emit both the old and new field names so that
consumers pinned to the older version continue to work.

### Stack export metadata

Every plugin stack emits an `_interopMeta` export alongside its named outputs, written by the
interop export helper called from `Plugin_Builder`:

```rescript
// reventless-interop/src/ExportMeta.res
@schema
type t = {
  version: string,            // reventless-interop package version, e.g. "1.2.0"
  fields: dict<array<string>> // { "tasks": ["name", "bucketNames"], "plugin": [...] }
}
```

The field lists are derived automatically as described above — not hardcoded.

```json
{
  "_interopMeta": {
    "version": "1.2.0",
    "fields": {
      "tasks": ["name", "bucketNames", "sideEffectSources"],
      "eventMappers": ["name", "eventCollector"],
      "plugin": ["id", "version", "readModels", "extensionPoints"]
    }
  }
}
```

### Projection API

Instead of consuming the entire `resolvedOutputs`, a consumer defines a **projection** — the
subset of fields it actually needs.

```rescript
// reventless-interop/src/Projection.res
module type T = {
  type t
  // Fields this projection requires (the publisher must have exported them)
  let requiredFields: array<string>
  // Fields this projection requests but tolerates being absent
  // (valid only when the corresponding field in t is option-typed)
  let optionalFields: array<string>
  // Decode from the raw JSON object after field validation passes
  let fromJson: Js.Json.t => result<t, string>
}
```

#### Query engine

```rescript
// reventless-interop/src/Query.res
module type StackQuery = {
  type t
  let queryAll: unit => Pulumi.Output.t<array<result<t, CompatError.t>>>
  let mergeWith: array<t> => Pulumi.Output.t<array<t>>
}

module Task = {
  module Make = (P: Projection.T) : (StackQuery with type t = P.t) => { ... }
}

module EventMapper = {
  module Make = (P: Projection.T) : (StackQuery with type t = P.t) => { ... }
}

module Plugin = {
  module Make = (P: Projection.T) : (StackQuery with type t = P.t) => { ... }
}
```

#### Consumer usage

A plugin that only needs task bucket URNs for a specific named bucket:

```rescript
module BucketQuery = ReventlessInterop.Query.Task.Make({
  @schema
  type t = { name: string, bucketNames: dict<string> }

  let requiredFields = ["name", "bucketNames"]
  let optionalFields = []

  let fromJson = json =>
    try {
      let r = json->S.parseOrThrow(ReventlessInterop.Task.resolvedOutputsSchema)
      Ok({ name: r.name, bucketNames: r.bucketNames->Option.getOr(Dict.make()) })
    } catch {
    | exn => Error(exn->Js.Exn.asJsExn->Option.flatMap(Js.Exn.message)->Option.getOr("parse error"))
    }
})
```

A plugin that needs the QueryDb resources from a named remote plugin:

```rescript
module RemoteQueryDb = ReventlessInterop.Query.Plugin.Make({
  @schema
  type t = { readModels: dict<ReventlessInterop.ReadModel.resolvedOutputs> }

  let requiredFields = ["readModels"]
  let optionalFields = []

  let fromJson = json =>
    try Ok(json->S.parseOrThrow(ReventlessInterop.Plugin.resolvedOutputsSchema))
    catch {
    | exn => Error(exn->Js.Exn.asJsExn->Option.flatMap(Js.Exn.message)->Option.getOr("parse error"))
    }
})
```

### Compatibility validation

```rescript
// reventless-interop/src/Compat.res
type error =
  | MissingRequiredField({ stackName: string, outputName: string, field: string })
  | MetaMissing({ stackName: string })
  | DecodeFailed({ stackName: string, reason: string })

let validateAndProject = (~meta: ExportMeta.t, ~outputName, ~rawJson,
                          ~requiredFields, ~optionalFields, ~fromJson) => {
  let available = meta.fields->Js.Dict.get(outputName)->Option.getOr([])->Belt.Set.String.fromArray
  switch requiredFields->Array.find(f => !Belt.Set.String.has(available, f)) {
  | Some(missing) => Error(MissingRequiredField({ stackName: meta.version, outputName, field: missing }))
  | None => fromJson(rawJson)->Result.mapError(r => DecodeFailed({ stackName: meta.version, reason: r }))
  }
}
```

If a required field is absent, the deployment fails with a clear error naming the stack, the
output, and the missing field — not a silent wrong-data condition.

---

## Part 2: Extension/Extension Point Protocol Versioning

### How the protocol works

An **ExtensionPoint** belongs to Plugin A and defines:
- A `CommandTopic` — extensions send commands here
- An `EventTopic` — extensions receive events from here
- Three message types: `command`, `event`, and `directive` (replacing `callCommand`)

An **Extension** belongs to Plugin B. It connects to Plugin A's extension point by:
- Subscribing to Plugin A's `EventTopic`
- Publishing to Plugin A's `CommandTopic`
- Implementing `mapIncomingEvent` and `mapOutgoingEvent` using the agreed message schemas

The two plugins are deployed independently on different cadences.

### Renaming `callCommand` to `directive`

The `callCommand` type holds instructions that the framework executes internally as a side effect
of processing a command or event — things like scheduling a timeout, forwarding a command to
another extension point, or triggering a plugin lifecycle action. These are not domain commands
sent externally and not domain events: they are **internal orchestration directives**.

Rename everywhere:

| Current | Replacement |
|---------|------------|
| `type callCommand` in `ExtensionPoint.Spec` | `type directive` |
| `type callCommand` in `ExtensionMapping.Spec` | `type directive` |
| `type callCommand` in `ExtensionPointMapping.Spec` | `type directive` |
| `callCommand` in `PluginExtensionPointSpec` | `directive` |
| `extensionPointCallCommand` type params | `directive` type params |

Example:

```rescript
// Before
module type Spec = {
  @schema type command
  @schema type event
  @schema type callCommand
}

// After
module type Spec = {
  @schema type command
  @schema type event
  @schema type directive
}
```

### Two versioning dimensions for the extension protocol

#### Dimension A: Infrastructure discovery (extension point `resolvedOutputs`)

When Plugin B deploys, it reads Plugin A's extension point topic URNs from the plugin stack export
via `Plugin.resolvedOutputs.extensionPoints`. This uses the projection API from Part 1 — no
separate mechanism needed.

#### Dimension B: Runtime message schema versioning

When Plugin B's extension encodes a `command` to send to Plugin A's extension point, and Plugin A
decodes it with `MappingSpec.commandSchema`, the schemas must be compatible. If they differ, the
message fails to decode silently.

The protocol has two directions and three schema types per direction:

```
Extension (Plugin B)   →  command  →  ExtensionPoint (Plugin A)
Extension (Plugin B)   ←  event    ←  ExtensionPoint (Plugin A)
                           directive: internal to each side
```

### Protocol version declarations

Each extension point's `Spec` carries a **protocol version** for its `command` and `event` schemas.
This is declared by the interop package for built-in extension points, or by application developers
for their custom extension points:

```rescript
// reventless-interop/src/protocol/ExtensionPointProtocol.res
type schemaVersions = {
  commandVersion: string,  // SemVer, e.g. "1.2.0"
  eventVersion: string,    // SemVer, e.g. "1.1.0"
}

module type Versioned = {
  module Spec: ReventlessSpec.ExtensionPointMapping.Spec
  let schemaVersions: schemaVersions
}
```

Application developers who define custom extension points declare their versions alongside their
`Spec` module by implementing `Versioned`, keeping interop concepts separate from the core spec.

### Connection handshake extension

The `ConnectPlugin(pluginDefinition)` command is already the mechanism by which Plugin B announces
itself to Plugin A's `Core.Plugin`. The `pluginDefinition` type is extended to include protocol
version information:

```rescript
// PluginExtensionPointSpec.res (or reventless-interop — see Open Questions)
@schema
type extensionProtocol = {
  extensionPointName: string,
  commandVersion: string,  // SemVer the extension was compiled with
  eventVersion: string,    // SemVer the extension was compiled with
}

@schema
type pluginDefinition = {
  id: string,
  name: name,
  version: version,
  extensionPoints: array<extensionPointDefinition>,
  extensions: array<extensionDefinition>,
  mutable eventCollector: string,
  // NEW:
  extensionProtocols: array<extensionProtocol>,
}
```

When Plugin B connects, Plugin A's `Core.Plugin` inspects `extensionProtocols` and validates
compatibility using the `reventless-interop` compatibility check:

```rescript
// reventless-interop/src/Compat.res (extended)
type protocolError =
  | IncompatibleCommandSchema({ extensionPointName: string, hostVersion: string, extensionVersion: string })
  | IncompatibleEventSchema({ extensionPointName: string, hostVersion: string, extensionVersion: string })

// SemVer rule: MAJOR must match; host MINOR/PATCH must be >= extension MINOR/PATCH
let validateProtocol:
  (~host: schemaVersions, ~extension: extensionProtocol) => result<unit, protocolError>
```

On incompatibility, `Core.Plugin`'s `ConnectPlugin` handler emits an `IncompatiblePlugin` event
(new variant to add alongside `UnknownPluginDetected`), giving operators visibility without
crashing the system.

### Additive-only evolution policy for message schemas

The SemVer policy for `@schema` message types differs from infrastructure types because runtime
codecs must handle **unknown data gracefully**:

| Change | Version bump | Runtime behaviour |
|--------|-------------|------------------|
| Add a new variant to `command`/`event` | MINOR | Old decoders must skip unknown variants gracefully |
| Add an optional field to a variant payload | MINOR | Old decoders ignore extra fields |
| Remove a variant or field | MAJOR | Old publishers send undecodable messages |
| Rename a variant | MAJOR | Rename = remove old + add new |
| Add a required field to an existing variant | MAJOR | Old publishers omit the field |

**Required pattern**: `@schema`-generated decoders for `command`/`event`/`directive` types must
use a catch-all branch for unknown variants (returning a `Result.Error` or skipping), not throw.
This prevents a single new variant from crashing a running Lambda that hasn't been redeployed.

---

## Package Structure

```
packages/reventless-interop/
├── package.json                      # name: @reventless/reventless-interop
├── rescript.json
└── src/
    ├── components/                   # Resolved output types (Output.t-free)
    │   ├── Task.res                  # type resolvedOutputs + @schema — primary cross-stack export
    │   ├── EventMapper.res           # type resolvedOutputs + @schema — primary cross-stack export
    │   ├── Plugin.res                # type resolvedOutputs + @schema — primary cross-stack export
    │   ├── ReadModel.res             # sub-type of Plugin.resolvedOutputs
    │   ├── ExtensionPoint.res        # sub-type of Plugin.resolvedOutputs
    │   ├── CommandTopic.res          # sub-type of ExtensionPoint.resolvedOutputs
    │   ├── EventTopic.res            # sub-type of ExtensionPoint.resolvedOutputs
    │   └── EventCollector.res        # sub-type where needed
    ├── protocol/                     # Extension point message schema versioning
    │   ├── ExtensionPointProtocol.res # schemaVersions type, Versioned module type
    │   └── CompatMatrix.res          # built-in compatibility declarations
    ├── ExportMeta.res                # _interopMeta type + fieldNamesOf helper
    ├── Projection.res                # Projection.T module type
    ├── Query.res                     # Query.Task.Make, Query.EventMapper.Make, Query.Plugin.Make
    ├── Compat.res                    # field + protocol compatibility validation
    └── InteropError.res              # unified error types
```

### Package dependencies

- `rescript-pulumi-pulumi` — for `Pulumi.Output.t`, `Pulumi.StackReference`
- `sury-ppx` — for `@schema` on resolved output types (generates `<typeName>Schema: S.t<'a>` values)
- **No dependency on `reventless-spec`** — resolved output types are independent definitions

### Dependency directions after this package exists

```
reventless-interop       (no upstream reventless dependencies)
       ↑
reventless               (depends on reventless-spec AND reventless-interop)
       ↑
reventless-aws           (depends on reventless, reventless-spec, reventless-interop)
       ↑
application code         (reventless-spec for defining plugin specs
                          reventless-interop for cross-stack queries + extension protocol)
```

---

## Relationship to `reventless-spec`

| Package | Contains | Used by |
|---------|---------|---------|
| `reventless-spec` | Spec module types, `outputs` types (with `Output.t`) | App devs (specs, behaviors), builders |
| `reventless-interop` | `resolvedOutputs` types, projection API, protocol versioning | App devs (cross-stack queries, extension connections), builders (export) |
| `reventless` | Component builders, adapters | `reventless-aws` |
| `reventless-aws` | AWS implementations | App composition roots |

Application developers have two independent touch points:
- `reventless-spec` for defining what their plugin **is**
- `reventless-interop` for declaring what their plugin **needs from others**

---

## Open Questions

1. **Where does `pluginDefinition` live after adding `extensionProtocols`?** Currently it is in
   `reventless-spec` (via `PluginExtensionPointSpec`). Adding interop concepts to a spec type is
   architecturally awkward. Options:
   - **A**: Extend the existing `pluginDefinition` in `reventless-spec` (leaks interop into spec)
   - **B**: Move `pluginDefinition` to `reventless-interop` (changes dependency direction)
   - **C**: Define a separate `interopPluginDefinition` in `reventless-interop` that wraps or
     extends `pluginDefinition` via structural extension — plugin B includes both
   Option C preserves clean separation and is preferred, but requires the `ConnectPlugin` handler
   to accept the extended type.

2. **sury-ppx catch-all for unknown variants**: Does sury-ppx support generating a catch-all
   decoder branch for `@schema` variant types? If not, the additive-only evolution policy for
   message schemas requires manual decoder boilerplate for extension point `command`/`event` types.

3. **`Plugin.resolvedOutputs` scope**: The current `Plugin_Helpers.pureOutputs` includes all
   component outputs (`aggregates`, `stateChangeSlices`, `heartbeat`, etc.) even though only
   `readModels` and `extensionPoints` are currently accessed cross-stack. The `Plugin.resolvedOutputs`
   in the interop package should include only fields that are actually used. Confirm whether any
   other plugin fields are accessed via `getRemoteStorageResources` or similar helpers that were
   added after the initial implementation.

4. **Custom extension point protocol declarations**: Application developers defining custom
   extension points need to declare protocol versions. The `module type Versioned` in
   `reventless-interop/src/protocol/` provides this — but it needs to be clear in the API where
   developers register their version declarations for use in the `ConnectPlugin` handshake.

---

## Implementation Phases

### ✅ Phase 0: PoC — DONE (commit 14a9f89b)
Create a minimal `reventless-interop` package with `Task.resolvedOutputs`. Verify it compiles
without circular dependencies and that `reventless`'s `Plugin_Builder` can depend on both packages.

### ✅ Phase 1: Resolved output types + export metadata — DONE (commit e706aabb)
Define all three primary `resolvedOutputs` types (Task, EventMapper, Plugin) and their sub-types.
Implement `ExportMeta.fieldNamesOf` and `ExportMeta.t`. Wire the export helper into `Plugin_Builder`
to emit `_interopMeta` alongside stack exports.

**Implementation notes:**
- Added `Resource.res` (shared `Output.t`-free resource type) and `Counter.res` beyond the plan's
  listed files — required to satisfy the type dependencies of ReadModel and EventMapper.
- `eventMappers` field manifest conservatively emits only required fields (`name`, `eventCollector`)
  because `counter` presence requires resolving nested `Pulumi.Output.t` values; will be improved
  in Phase 3 when the full `resolvedOutputs` conversion is wired in.
- Stack exports remain top-level `let` bindings in user code (Pulumi Node.js architecture). Plugin
  entry-point modules call `Plugin_Helpers.getInteropMeta()` and export the result as
  `let _interopMeta = ...` alongside `tasks`, `plugin`, and `eventMappers`.

### ✅ Phase 2: Compatibility validation + query engine — DONE (commit e0d05ce3)
Implement `Compat.validateAndProject`. Implement `Query.Task.Make`, `Query.EventMapper.Make`,
`Query.Plugin.Make`. Write unit tests for all compatibility scenarios.

**Implementation notes:**
- `Compat.res`: `error` type with `MissingRequiredField`, `MetaMissing`, `DecodeFailed` variants;
  `validateAndProject` checks required fields against the field manifest, then delegates to `fromJson`.
- `Projection.res`: `module type T` with `requiredFields`, `optionalFields`, `fromJson`.
- `Query.res`: module-level `stackEntries` (same pattern as `Interstack.stackDependencies`);
  internal helpers `queryAllArray` (for tasks/eventMappers) and `queryAllSingle` (for plugin);
  `Task.Make`, `EventMapper.Make`, `Plugin.Make` functors producing `StackQuery`.
  - Uses `Obj.magic` to coerce untyped Pulumi stack outputs to `JSON.t` for sury parsing (safe
    because Pulumi deserialises JSON before returning values via `StackReference.getOutput`).
  - `ExportMeta.t` schema is named `ExportMeta.schema` (not `tSchema`) — ppx generates `schema`
    for types named `t`.
- `CompatTest.res`: 14 Jest tests covering all field validation scenarios, `fromJson` delegation,
  error wrapping, and boundary cases. All 14 pass.

### ✅ Phase 3: Replace unchecked casts — DONE (commit b3c132e9)
Replace `Interstack.stackDependenciesTasks` and `Interstack.stackDependenciesEventMappers` with
the query engine (breaking change to their return types: `result<t, CompatError.t>` instead of `t`).
Replace `Plugin_Helpers.pureOutputs` with `ReventlessInterop.Plugin.resolvedOutputs`.
Remove `CommandTopic.unwrappedOutputs`, `EventTopic.unwrappedOutputs`,
`ExtensionPoint.unwrappedOutputs` — replaced by their `resolvedOutputs` counterparts.

**Implementation notes:**
- `CommandTopic.toUnwrappedOutputs`, `EventTopic.toUnwrappedOutputs`, `ExtensionPoint.toUnwrappedOutputs`
  renamed to `toResolvedOutputs`, returning interop types with `Resource.t` instead of `Adapter.unwrappedResource`.
- `Adapter.res` gains `fromInteropUnwrapped`, `fromInteropResource`, `fromInteropResources` helpers
  to bridge `ReventlessInterop.Resource.t` ↔ `Adapter.unwrappedResource` ↔ `ReventlessSpec.Adapter.resource`
  (types are structurally identical at runtime).
- `AdapterDeploytime.fromInteropResource` added for deploy-time stack-export-to-resource conversion.
- `Plugin_Helpers.pureOutputs` renamed to `builderOutputs` (local-only type; cross-stack consumers
  use `ReventlessInterop.Plugin.resolvedOutputs`).
- `getRemoteStorageResources` now reads `_interopMeta` + `plugin` via `getOutput`, validates with
  `Compat.validateAndProject`, and decodes with sury instead of an unchecked cast.
- `Plugin_Builder.res`: `corePluginExtensionPointUnwrapped` type changed from `ExtensionPoint.unwrappedOutputs`
  to `ReventlessInterop.ExtensionPoint.resolvedOutputs`, with a sury schema parse replacing the unchecked cast.
- `PluginConnectExtension_Builder.Spec.extensionPointsOutputs` type updated to use interop type.
- `Interstack.resi` updated: `mergeTasks`/`mergeEventMappers` now accept/return interop resolved
  output types; `stackDependenciesTasks`/`stackDependenciesEventMappers` added to the interface.

### ✅ Phase 4: `directive` rename — DONE
Rename `callCommand` to `directive` across `ExtensionPoint.Spec`, `ExtensionMapping.Spec`,
`ExtensionPointMapping.Spec`, and `PluginExtensionPointSpec`. Update all downstream uses.

**Implementation notes:**
- `type callCommand` → `type directive` in `ExtensionPoint.Spec`, `ExtensionMapping.Spec`,
  `ExtensionPointMapping.Spec`, and `PluginExtensionPointSpec`.
- `'extensionPointCallCommand` type params → `'extensionPointDirective` in `ExtensionMapping.res`
  and `ExtensionPointMapping.res`.
- `ExtensionPoint.callCommand` references → `ExtensionPoint.directive` in `Impl` module types.
- `Spec.callCommandSchema` → `Spec.directiveSchema` in both mapping implementation files
  (ppx generates `directiveSchema` for `type directive`).
- Local variable names `callCommand`/`callCmd` renamed to `directive` in
  `ExtensionMapping.res`, `ExtensionPointMapping.res`, and `PluginExtensionPoint_Plugin.res`.
- `and type callCommand = Spec.callCommand` constraint in `ExtensionPoint_Builder.res` updated.
- All three packages (`reventless-spec`, `reventless`, `reventless-aws`) build without errors.

### ✅ Phase 5: Protocol version handshake — DONE
Resolved Open Question 1 (pragmatic Option A — `extensionProtocols` added directly to
`pluginDefinition` in `reventless-spec` as a required array with `[]` for no-version-check).
Added `extensionProtocols` to the `ConnectPlugin` handshake. Implemented
`Compat.validateProtocol`. Updated `Core.Plugin`'s `ConnectPlugin` handler to warn on mismatch.

**Implementation notes:**
- `extensionProtocol` type added to `reventless-spec/Plugin.res` with `extensionPointName`,
  `commandVersion`, `eventVersion` fields.
- `extensionProtocols: array<extensionProtocol>` added to `pluginDefinition` as a required
  field (not optional — `S.option` causes `S.reverseConvertToJsonOrThrow` validation to fail
  because `undefined` type is rejected by sury's `jsonableValidation` in the reversed schema).
  Existing construction sites updated to use `extensionProtocols: []`.
- `IncompatiblePlugin(pluginDefinition)` added to `PluginExtensionPointSpec.event`.
- `ReportIncompatibility(pluginDefinition)` added to `PluginSpec.command`; emits
  `IncompatiblePluginDetected(pluginDefinition)` aggregate event (no state change).
- `PluginBehavior.apply` handles `IncompatiblePluginDetected` as a no-op in all states.
- `mapOutgoingEvent` maps `IncompatiblePluginDetected` → `IncompatiblePlugin` extension event.
- `mapIncomingCommand` for `ConnectPlugin` validates `extensionProtocols` against
  `ReventlessInterop.CompatMatrix.corePlugin` versions, logs a warning and emits
  `ReportIncompatibility` alongside `Connect` when mismatches are found.
- `reventless-interop/src/protocol/ExtensionPointProtocol.res` — `schemaVersions` type.
- `reventless-interop/src/protocol/CompatMatrix.res` — Core.Plugin versions (`"1.0.0"`).
- `Compat.res` extended with `protocolError` type and `validateProtocol` function using SemVer
  comparison (MAJOR must match; host MINOR/PATCH must be ≥ extension MINOR/PATCH).
- All three packages (`reventless-spec`, `reventless`, `reventless-aws`) build without errors.
- 103 tests in `reventless` + 14 tests in `reventless-interop` pass.

### ✅ Phase 6: Schema registry for built-in extension points — DONE
Populate `protocol/CompatMatrix.res` with the version declarations for built-in extension points
(`Core.Plugin`). Document the pattern for custom extension points.

**Implementation notes:**
- `CompatMatrix.res`: enhanced comments listing the `Core.Plugin` command/event variant inventory
  and explaining that custom EPs declare their own `schemaVersions` locally — no central registry.
- `ExtensionPointProtocol.res`: added `module type Versioned` (`name: string` + `schemaVersions`)
  for custom EP authors, with usage examples in comments (kept free of `reventless-spec` dep).
- New doc page `docs-framework/architecture/extension-point-protocol-versioning.md` covering:
  the handshake flow, compatibility rule, SemVer policy, built-in EP version table, and the
  full custom EP pattern (declaring versions, validating incoming connections, bumping on change).
- `sidebars-framework.js` updated to include the new doc page.
