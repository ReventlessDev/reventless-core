# Analysis: Declarative Trigger Specification for InboundTranslationSlice

## Problem

The `InboundTranslationSlice` is the only DCB slice type where the framework leaves the "how does data arrive?" question unanswered. AutomationSlice and OutboundTranslationSlice subscribe to domain events — the framework handles the full lifecycle. InboundTranslationSlice only exposes an `operations.receive(JSON.t)` function and expects the application developer to hand-wire it to an external entry point (API route, webhook endpoint, SQS queue, etc.) outside the framework.

This breaks the declarative pattern the rest of the framework provides. The goal is to let the spec author declare the trigger source, and have the framework provision all necessary infrastructure automatically.

## Current State

### What InboundTranslationSlice provides today

```
External caller (hand-wired) → operations.receive(JSON.t) → parse → translate → publishJsons → CommandTopic
```

The spec defines `externalInput`, `command`, and `translate`. The builder creates an audit QueryDb and the `receive` function. But nothing connects `receive` to the outside world.

### How other components handle their triggers

| Component | Trigger Source | Provisioned By |
|---|---|---|
| StateChangeSlice | CommandTopic (SQS queue) | Framework (CommandTopicChannel) |
| StateViewSlice | EventTopic (SNS → SQS) | Framework (EventCollectorChannel) |
| AutomationSlice | EventTopic + Scheduler | Framework (EventCollectorChannel + HeartbeatRunner) |
| OutboundTranslationSlice | EventTopic + Scheduler | Framework (EventCollectorChannel + HeartbeatRunner) |
| CommandGenerator | AppSync GraphQL mutation | Framework (CommandGeneratorResolvers) |
| Extension | EventTopic (cross-plugin) | Framework (ExtensionMapping) |
| **InboundTranslationSlice** | **Nothing — hand-wired** | **Developer's responsibility** |

### How the API system works (relevant context)

The framework has a complete GraphQL API system:
- Schema fragments are auto-generated from `@schema` annotations on commands/states
- Fragments are stitched at runtime when plugins connect
- AppSync resolvers (AWS) or graphql-yoga routes (in-memory) are provisioned at deploy time
- Mutations route to CommandTopic Lambdas, queries route to QueryDb Lambdas

This means the framework already knows how to expose typed endpoints from schema definitions — the InboundTranslationSlice just isn't connected to it.

## Requirements

1. The spec author must be able to declare the trigger source declaratively
2. The framework must provision all infrastructure (Lambda, API route, SQS queue, etc.)
3. The solution must work across platforms (AWS, in-memory, future platforms)
4. It must integrate with the existing schema/API system where applicable
5. Multiple trigger types should be supportable (not just HTTP)

## Alternatives

### Alternative A: GraphQL Mutation (API-integrated)

Add the InboundTranslationSlice as a mutation endpoint in the existing GraphQL API, similar to how CommandGenerator exposes aggregate commands as mutations.

**Spec change:**

```rescript
module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema type externalInput
  @schema type command
  let translate: externalInput => result<(string, command), string>
}
```

No spec change needed — the existing `externalInput` schema is sufficient. The builder uses `externalInputSchema` to generate a mutation field like `PluginName_SliceName(input: ExternalInputType!): String!`.

**Infrastructure provisioned:**
- AWS: AppSync resolver → Lambda DataSource → `receive` function
- In-memory: graphql-yoga mutation resolver → `receive` function

**Wiring:** The Plugin builder adds one mutation schema entry per InboundTranslationSlice (same pattern as StateChangeSlice mutations). The resolver invokes `receive` with the mutation arguments serialized as JSON.

**Advantages:**
- Zero spec changes — works with the existing spec
- Consistent with how the rest of the API works
- Authentication/authorization comes for free (AppSync auth, Cognito groups)
- Schema is auto-generated and type-safe
- Works for both AWS and in-memory platforms today
- GraphiQL provides a built-in testing UI

**Disadvantages:**
- Only covers synchronous HTTP request/response
- Not suitable for asynchronous sources (SQS, S3, webhooks with specific URL paths)
- Couples external input format to GraphQL mutation syntax

**Implementation scope:** Small. The fragment generator already handles mutation entries from StateChangeSlices. Adding InboundTranslationSlice entries follows the same pattern — one mutation field per slice, with the `externalInput` type as arguments.

---

### Alternative B: Trigger Source Enum in Spec

Add a `trigger` field to the spec that declares how the slice should be invoked.

**Spec change:**

```rescript
type trigger =
  | ApiMutation                          // GraphQL mutation (Alternative A)
  | Webhook({path: string})             // Dedicated HTTP endpoint
  | Queue({name: string})              // SQS/equivalent queue
  | Schedule({cron: string})           // Periodic polling

module type Spec = {
  // ... existing fields ...
  let trigger: trigger
}
```

**Infrastructure provisioned per trigger type:**
- `ApiMutation`: Same as Alternative A
- `Webhook({path})`: API Gateway HTTP route → Lambda → `receive`. The `path` becomes a route like `POST /webhooks/{path}`. Returns HTTP status codes mapped from the `result`.
- `Queue({name})`: SQS queue → Lambda → `receive`. Each message body is passed as `inputJson`. Dead-letter queue provisioned automatically.
- `Schedule({cron})`: CloudWatch Events rule → Lambda. The `externalInput` would need to come from somewhere (e.g., polling an external API). Less clear use case.

**Advantages:**
- Covers all common integration patterns
- Declarative — spec author just picks the trigger type
- Each trigger type maps cleanly to well-understood AWS primitives
- Webhook path gives the developer control over URL structure

**Disadvantages:**
- More complex to implement (each trigger type needs platform adapters)
- `Schedule` is awkward — where does the input come from?
- `Webhook` needs a separate API Gateway (or a route on the existing one), adding infrastructure complexity
- The trigger type leaks infrastructure concerns into the domain spec
- Platform adapters need to implement all trigger variants

**Implementation scope:** Medium-large. Each trigger type needs adapters for AWS and in-memory. The webhook variant needs HTTP server/API Gateway infrastructure that doesn't exist yet.

---

### Alternative C: Separate Trigger Adapter (Platform-Level)

Keep the spec unchanged. Instead, let the Plugin wiring layer declare how each InboundTranslationSlice is triggered, using platform-provided trigger adapters.

**Spec:** Unchanged.

**Plugin wiring change:**

```rescript
// In CatalogPlugin.res
module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

// NEW: declare trigger at the plugin level
module ImportProductTrigger = Platform.InboundTrigger.ApiMutation(ImportProductSlice)
// or
module ImportProductTrigger = Platform.InboundTrigger.Webhook(ImportProductSlice, {path: "/import-product"})
// or
module ImportProductTrigger = Platform.InboundTrigger.Queue(ImportProductSlice, {name: "supplier-imports"})
```

And the DcbSpec would reference the triggers:

```rescript
let inboundTranslationSlices = [module(ImportProductSlice)]
let inboundTriggers = [module(ImportProductTrigger)]
```

**Advantages:**
- Spec stays pure domain logic — no infrastructure concerns
- Plugin author chooses the trigger at composition time
- Same slice can be triggered differently in different deployments
- Platform implements only the trigger types it supports
- Clean separation: spec = what to do, trigger = how to invoke it

**Disadvantages:**
- More boilerplate in the plugin file (two modules per slice instead of one)
- Trigger types still need platform adapters
- The link between slice and trigger is implicit (both must be listed)

**Implementation scope:** Medium. Similar adapter work as Alternative B, but with cleaner separation.

---

### Alternative D: Default to API Mutation, Optional Override

Combine A and B: every InboundTranslationSlice automatically gets a GraphQL mutation endpoint (the common case). The spec can optionally declare additional or alternative triggers.

**Spec change:**

```rescript
module type Spec = {
  // ... existing fields ...
  let trigger: option<trigger>  // None = ApiMutation (default)
}
```

Or better — no spec change, and the default is always ApiMutation. Additional triggers are declared at the plugin level (Alternative C style) when needed.

**Advantages:**
- Zero-config for the common case (API mutation)
- Opt-in complexity for advanced use cases
- Backwards compatible

**Disadvantages:**
- Two mechanisms to understand
- "Default magic" can be surprising

---

## Recommendation

**Start with Alternative A (GraphQL Mutation), design for Alternative C extensibility.**

**Implementation plan**: [`docs/plans/inbound-translation-slice-api-mutation.md`](../plans/inbound-translation-slice-api-mutation.md)

Rationale:

1. **Alternative A covers the primary use case.** Most inbound translation scenarios are "receive data from an external system via HTTP" — exactly what a GraphQL mutation provides. The framework already has all the machinery for this (schema generation, resolver provisioning, auth). The implementation is small and consistent.

2. **The spec stays unchanged.** The existing `externalInput` and `command` types already carry `@schema` — everything needed to generate the mutation endpoint. No breaking changes.

3. **Alternative C is the right extension point for non-HTTP triggers.** When webhook endpoints with specific paths, SQS queues, or other trigger types are needed, the platform-level trigger adapter pattern (Alternative C) keeps infrastructure concerns out of the domain spec. This can be added later without changing the existing API mutation behavior.

4. **Alternative B is too eager.** Putting trigger type in the spec mixes infrastructure and domain concerns. The spec should describe *what* the anti-corruption layer does, not *how* it's invoked.

5. **Alternative D is Alternative A + C without the naming.** The recommendation is essentially this — but framed as "A now, C later" rather than a hybrid that's harder to explain.

## Implementation Sketch for Alternative A

### Changes needed

**1. Plugin_Builder (schema generation)**

In the plugin builder's schema generation phase, add one mutation entry per InboundTranslationSlice:

```rescript
// For each InboundTranslationSlice in dcbSpec:
let mutationEntry: mutationSchemaEntry = {
  fieldNames: [`${pluginName}_${sliceName}`],
  commandSchema: Obj.magic(Spec.externalInputSchema),  // Input type becomes mutation args
}
```

The mutation field name follows the existing convention: `PluginName_SliceName` (e.g., `Catalog_ImportProduct`).

**2. GraphQL_FragmentGenerator**

The fragment generator already handles mutation entries. The InboundTranslationSlice entry is structurally identical to a StateChangeSlice entry — just with `externalInputSchema` instead of `commandSchema` for the argument types.

**3. Resolver wiring (AWS)**

Create an AppSync resolver that invokes the InboundTranslationSlice's Lambda. The resolver passes mutation arguments as JSON to `receive`:

```velocity
{
  "version": "2017-02-28",
  "operation": "Invoke",
  "payload": $utils.toJson($context.arguments)
}
```

The Lambda handler calls `operations.receive(payload)` and returns the result.

**4. Resolver wiring (In-Memory)**

Add a graphql-yoga mutation resolver that calls `operations.receive(args)` directly.

**5. InboundTranslationSlice_Builder**

The builder already creates the `receive` function. The only addition is making the component's outputs include resolver resources (same pattern as CommandGenerator).

### What the developer sees

Before (today):
```rescript
// ImportProduct.res — spec only, no trigger
// CatalogPlugin.res — wires the slice, but no API exposure
// Developer must hand-wire receive() to some HTTP handler
```

After:
```rescript
// ImportProduct.res — unchanged
// CatalogPlugin.res — unchanged
// Framework auto-generates: Catalog_ImportProduct(sku: String!, title: String!, ...) mutation
// Framework auto-provisions: AppSync resolver → Lambda → receive()
```

The developer writes the spec, wires it in the plugin, and gets a working API endpoint with zero additional configuration.
