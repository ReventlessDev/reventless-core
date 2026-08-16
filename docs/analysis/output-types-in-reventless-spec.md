# Output Types in `reventless-spec`: Why They Belong There

## Question

Why do we need all the output types for the components defined in `reventless-spec`? Are they really needed for application developers, or could we move them into the `reventless` package?

## What the Output Types Are

Every component module in [`packages/reventless-spec/src/components/`](https://github.com/ReventlessDev/reventless-core/tree/alpha/reventless/spec/src/components/) defines a `type outputs` (and sometimes `type allOutputs`, `type operations`). Examples:

- [`Aggregate.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/Aggregate.res) — `{name, commandGenerator, commandTopic, eventLog, eventMapper?, addEventMapper}`
- [`Plugin.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/Plugin.res) — `{id, version, heartbeatInterval, eventCollector, extensionPoints, …}`
- [`ReadModel.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/ReadModel.res) — `{name, queryDb, eventCollector, sourceNames}`
- [`EventTopic.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/EventTopic.res) — `{resources}`
- etc.

## Who Actually Uses These Types?

### 1. The `reventless` Package (Framework Internals) — Heavily

Every component builder in `packages/reventless/src/components/` re-exports the spec's output type as its own:

```rescript
// packages/reventless/src/components/Aggregate/Aggregate.res
type outputs = Reventless.Aggregate.outputs
```

The builders construct values of these types (e.g. [`Aggregate_Builder.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Aggregate/Aggregate_Builder.res)), pass them between components (e.g. [`Plugin_Helpers.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Plugin/Plugin_Helpers.res)), and use them in cross-component wiring (e.g. `Plugin_Helpers.extractExtensionPointDefinitions` takes `array<ExtensionPoint.outputs>`).

### 2. The `reventless` Package — Cross-Stack Interop via `Interstack`

#### What `Interstack` Does

[`Interstack.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/util/Interstack.res) is a **cross-stack dependency resolver** for Pulumi multi-stack deployments. In a Pulumi architecture, a large application is split into multiple independently-deployed stacks (e.g. a "core" infrastructure stack and several "plugin" stacks). `Interstack` is the mechanism by which one stack reads the **exported outputs** of another stack at deploy time.

It works in three steps:

1. **Reads stack references from Pulumi config** — it reads `interstack.dependencies` (a list of stack names) and optionally a `core.stack` reference. Each name is turned into a `Pulumi.StackReference`.

2. **Fetches named outputs from all dependency stacks** — `getOutputs(name)` queries every dependency stack for a named export (e.g. `"tasks"` or `"eventMappers"`) and collects all results into a single `Pulumi.Output.t<array<'a>>`.

3. **Deserializes those outputs into typed records** — the two concrete bindings:

```rescript
let stackDependenciesTasks: Pulumi.Output.t<array<Task.outputs>> = getOutputs("tasks")
let stackDependenciesEventMappers: Pulumi.Output.t<array<EventMapper.outputs>> = getOutputs("eventMappers")
```

Pulumi stack outputs are **serialized JSON** at rest. When `getOutputs` fetches them, Pulumi deserializes the JSON back into JavaScript objects. ReScript's structural typing means the type annotation `array<Task.outputs>` is a **cast** — it asserts that the JSON shape matches the record type. If the type definition changes, the deserialization silently produces wrong data.

4. **Provides merge helpers** — `mergeTasks` and `mergeEventMappers` combine the remote stack's outputs with the current stack's locally-built outputs, giving the current stack a unified view of all tasks/event mappers across the entire deployment.

#### Who Uses `Interstack`

- **Application developers** — directly, when they call `Interstack.mergeTasks(localTasks)` or `ResourceQueryRuntime.bucketNameOfAllTasks(...)`. These are the primary user-facing APIs for cross-stack resource sharing. At that point they work with `Task.outputs` values.
- **[`Plugin_Helpers.getRemoteStorageResources`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Plugin/Plugin_Helpers.res)** — fetches the `"plugin"` output from a remote stack and casts it to `pureOutputs`, which is structurally identical to `Plugin.outputs` but with all `Pulumi.Output.t<_>` wrappers stripped (because stack outputs are already resolved JSON). Used when one plugin stack needs to read the `QueryDb` resources of another plugin stack.

#### The Serialization Chain

```
Stack A deploys                    Stack B deploys
──────────────                     ──────────────
Task.make(...)                     Interstack.getOutputs("tasks")
  → Task.outputs record            → Pulumi fetches JSON from Stack A
  → exported as "tasks" JSON       → cast to array<Task.outputs>
```

The JSON that crosses the stack boundary looks like:
```json
[{ "name": "MyTask", "bucketNames": { "Bucket": "my-bucket-xyz" } }]
```

There is **no runtime type checking** here. The cast is purely a compile-time assertion. The actual deserialization is structural — the JSON field names must match the record field names exactly. This makes the output types a **public, versioned, cross-stack serialization contract**.

[`Plugin_Helpers.getRemoteStorageResources`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Plugin/Plugin_Helpers.res) deserializes a remote stack's `"plugin"` output as `pureOutputs` (structurally identical to `Plugin.outputs` but unwrapped). These types must be stable and shared because they **cross Pulumi stack boundaries as serialized JSON**.

### 3. The `reventless-spec` Itself — Cross-Component References

The output types reference each other within the spec. For example:

- [`Aggregate.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/Aggregate.res) references `CommandGenerator.outputs`, `CommandTopic.outputs`, `EventLog.outputs`, `EventMapper.outputs`
- [`ReadModel.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/ReadModel.res) references `QueryDb.outputs`, `EventCollector.outputs`
- [`Plugin.outputs`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/components/Plugin.res) references nearly all other component output types

This creates a dependency graph entirely within `reventless-spec`.

### 4. Application Developers — Indirectly, But Not Directly

Application developers use `reventless-aws` (e.g. [`Plugin.res`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/aws/src/components/Plugin.res)) which wraps everything. They call `Plugin.make(...)` and get back a `component`. They never need to name `Plugin.outputs` or `Aggregate.outputs` explicitly in their own code — the types flow through type inference.

The **one exception** is cross-stack interop: if an app developer uses `Interstack.mergeTasks` or `ResourceQueryRuntime.bucketNameOfAllTasks`, they work with `Task.outputs` values. But even then, they *consume* the type, not define it.

## Could the Output Types Be Moved Back into `reventless`?

**Technically yes, but with significant complications:**

### Problem 1: Cross-Component References Within the Spec

`Aggregate.outputs` references `CommandTopic.outputs`, `EventLog.outputs`, etc. If moved to `reventless`, these would all need to live in the same package anyway, so the circular dependency problem doesn't go away — it just moves.

### Problem 2: Cross-Stack Serialization Contract

The output types define the shape of Pulumi stack outputs that are serialized to JSON and read back by other stacks via `Interstack`. This is a **public contract** that must be stable.

The specific risk: Stack A might be deployed with `reventless@1.0` and Stack B with `reventless@1.1`. If `Task.outputs` changed between versions (a field renamed, added, or removed), Stack B would silently deserialize Stack A's JSON into a structurally wrong record — no compile error, no runtime error, just wrong data at deploy time. There is no Decco/schema validation at the `Interstack` boundary; the cast is unchecked.

Keeping the output types in `reventless-spec` (which is versioned independently and more conservatively than `reventless`) makes this contract explicit, separately lockable, and independently versioned from the implementation. If the types lived in `reventless`, every patch release of the framework implementation would be a potential breaking change to the cross-stack serialization contract.

### Problem 3: The `reventless-spec` Package's Purpose

The spec package defines the *interface* between application developers and the framework — the `module type Spec` / `module type T` signatures that app developers implement, plus the `operations` types they receive at runtime. The `outputs` types are part of this interface because they describe what a component *produces* at deploy time (Pulumi resources). Moving them to `reventless` would blur the spec/implementation boundary.

### Problem 4: The `Adapter.resource` Dependency

Output types depend on [`Adapter.resource`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/spec/src/adapter/Adapter.res) which is also in `reventless-spec`. This is intentional — it's a spec-level abstraction over cloud resources. If outputs moved to `reventless`, they'd still need to reference `Adapter.resource` from `reventless-spec`, creating a cross-package dependency in the wrong direction.

### Problem 5: The `pureOutputs` Unwrapping Pattern

[`Plugin_Helpers`](https://github.com/ReventlessDev/reventless-core/blob/main/reventless/core/src/components/Plugin/Plugin_Helpers.res) defines a `pureOutputs` type that is structurally identical to `Plugin.outputs` but with every `Pulumi.Output.t<X>` replaced by plain `X`. This is necessary because when a remote stack's `"plugin"` export is fetched via `Interstack`, Pulumi has already resolved all the `Output` wrappers — the result is plain JSON, not `Pulumi.Output.t<_>` values.

This `pureOutputs` type must stay in sync with `Plugin.outputs` manually. If the output types lived in `reventless`, this mirroring relationship would be between two types in the same package, making it easy to change one without updating the other and breaking cross-stack deserialization silently. Keeping `Plugin.outputs` in `reventless-spec` makes the canonical definition clearly separate from the implementation-internal `pureOutputs` mirror.

## Conclusion

The output types **belong in `reventless-spec`** for these reasons:

1. **Cross-component interface**: `Aggregate.outputs` is referenced by `Plugin.outputs` and other spec types — the spec is self-contained.
2. **Cross-stack serialization contract**: Pulumi stack outputs are typed by these records and deserialized by `Interstack` without runtime validation; they must be stable and independently versioned from the implementation.
3. **Public API surface**: Application developers encounter these types when using interstack utilities like `Interstack.mergeTasks` or `ResourceQueryRuntime`.
4. **Spec/implementation separation**: The `reventless-spec` package defines the *contract*; the output types are part of that contract, not an implementation detail.
5. **`Adapter.resource` dependency and `pureOutputs` mirroring**: Output types depend on `Adapter.resource` (a spec-level abstraction), and `Plugin_Helpers` maintains a `pureOutputs` mirror for cross-stack deserialization. Both concerns belong at the spec level.

Application developers never *define* values of these types, but they are part of the observable interface of the framework. The `reventless-spec` package is the right home for them.
