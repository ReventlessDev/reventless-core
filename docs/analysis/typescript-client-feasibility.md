# TypeScript Client Feasibility Analysis

## Summary

TypeScript clients can use Reventless today in two narrow ways without any framework
changes, and can be given a first-class experience with a moderate investment. The
feasibility depends entirely on which of three distinct "client" scenarios is meant.

| Scenario | Feasibility | Effort |
|---|---|---|
| 1. Runtime API client (REST/GraphQL consumer) | ✅ Works today | None |
| 2. Pulumi infrastructure composition | 🟡 Works with small glue layer | Small |
| 3. Full framework user (TS aggregates / read models) | 🔴 Blocked by fundamental constraints | Large |

---

## Scenario 1: Runtime API Client

A TypeScript application that **dispatches commands and reads query results** from a
running Reventless-powered API. This is a pure REST/GraphQL consumer.

**Current state:** Works today. No framework dependency required.

Commands are dispatched as JSON payloads. The AppSync/GraphQL API is generated from
ReadModel schemas. A TypeScript client only needs to know the JSON shape of each command
and the GraphQL schema for queries.

**DX today:**
```typescript
// Submit a command — plain JSON, framework-agnostic
await fetch('/api/graphql', {
  method: 'POST',
  body: JSON.stringify({
    query: `mutation { submitCommand(input: $input) }`,
    variables: {
      input: {
        commandType: 'AddProduct',
        payload: { productId: 'p-1', name: 'Widget', price: 9.99 }
      }
    }
  })
})
```

**DX with a thin generated client:**

The framework already generates GraphQL schemas from `@schema`-annotated ReScript types.
A generated TypeScript client SDK (e.g. via GraphQL Code Generator) would give full
type safety at zero additional framework cost:

```typescript
import { AddProductCommand, GetProductQuery } from './generated/catalog.sdk'

await client.addProduct({ productId: 'p-1', name: 'Widget', price: 9.99 })
const product = await client.getProduct({ id: 'p-1' })
```

**Verdict:** GraphQL Code Generator pointed at the generated schema is the complete
solution. No framework changes needed.

---

## Scenario 2: Pulumi Infrastructure Composition

A TypeScript Pulumi program that uses **Reventless components as building blocks**
alongside other Pulumi resources.

**Current state:** Technically works today; DX is poor.

The compiled `.res.mjs` files export real JavaScript functions. Pulumi components are
`ComponentResource` subclasses — standard Pulumi. A TypeScript program can call the
compiled factories, but without `.d.ts` declarations everything is `any`.

**Blockers:**
- No TypeScript declarations (`.d.ts`) generated for any compiled module
- The functor pattern (`Make(Spec)(Behavior)(EventMappings)(...)`) compiles to deeply
  curried functions with no discoverable types
- Sury-ppx `@schema` annotations are compile-time ReScript transforms; TypeScript cannot
  produce them

**What would be needed:**

### 2a. Automatically generated `.d.ts` via `@genType`

`@genType` is a first-party ReScript tool that reads annotated `.res` type and value
declarations and emits `.d.ts` files as part of the build. This is the right tool for
keeping output type declarations in sync automatically — no manual maintenance.

**What @genType can cover — output record types**

The output records (`Aggregate.outputs`, `ReadModel.outputs`, `Plugin.outputs`) are
plain ReScript records. Annotating them with `@genType` generates accurate TypeScript
declarations automatically and keeps them in sync with the ReScript source:

```rescript
// reventless-spec: Aggregate.res
@genType
type outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventLog: EventLog.outputs,
  // ...
}
```

Generates:
```typescript
// Aggregate.gen.d.ts — auto-generated, never edited by hand
export type AggregateOutputs = {
  name: string,
  commandTopic: Output<CommandTopicOutputs>,
  eventLog: EventLogOutputs,
  // ...
}
```

**The critical prerequisite: mapping `Pulumi.Output.t<'a>`**

`Pulumi.Output.t<'a>` is bound as an opaque type (`type t<'a> = {}`) in
`rescript-pulumi-pulumi`. Without a mapping, `@genType` would emit `{}` — useless.
The fix is a single annotation in `Output.res`:

```rescript
// rescript-pulumi-pulumi/src/Output.res
@genType.import(("@pulumi/pulumi", "Output"))
type t<'a>
```

This instructs `@genType` to substitute `Output<A>` from `@pulumi/pulumi` (which ships
full TypeScript declarations) wherever `Output.t<'a>` appears. The real Pulumi type
propagates through all generated output declarations for free.

**What @genType cannot cover — the composition/factory API**

The entire `Platform.T` and component `Make` surface uses ReScript module functors:

```rescript
module Make: (
  Spec: Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
) => Aggregate.T
```

`@genType` does not support module functors. They compile to deeply curried JS functions
where each argument is a module object — there is no TypeScript type that can express
this pattern. The factory/composition API must remain in ReScript or be hand-declared
separately (see 2b).

**Architectural implication**

This draws a natural boundary for Scenario 2:

- **Component construction (Plugin composition) stays in ReScript.** The functor API is
  never exposed to TypeScript.
- **TypeScript reads outputs from pre-built components.** TypeScript Pulumi programs
  receive already-constructed components and use the `@genType`-generated output types
  to wire them to other resources.

In this split, `@genType` on the output types covers exactly what TypeScript needs.

### 2b. Exposing declarations via npm `exports`

Currently the packages lack an `exports` field. Adding it with `types` subpaths makes
the IDE experience reliable:

```json
{
  "exports": {
    ".": {
      "types": "./src/index.gen.d.ts",
      "default": "./src/index.res.mjs"
    }
  }
}
```

The `index.gen.d.ts` is the barrel file produced by `@genType`, re-exporting all
annotated types from the package.

**Verdict:** Achievable with a small upfront investment — add `@genType` to the build
pipeline, annotate the output types in `reventless-spec`, and add the `Pulumi.Output.t`
import mapping. Output declarations stay in sync automatically thereafter. The functor
composition API remains in ReScript; TypeScript only touches the output wiring layer.

---

## Scenario 3: Full Framework User (TypeScript Aggregates and Read Models)

A TypeScript developer who wants to define **aggregates, behaviors, projections, and
plugins entirely in TypeScript**, the way a ReScript developer does today.

This is the richest scenario and the hardest. The blockers are structural:

### Blocker 1: sury-ppx — the schema generation problem

The most fundamental blocker. The `@schema` PPX attribute generates JSON serialization
schemas at **compile time from the ReScript type system**:

```rescript
// ReScript — PPX transforms this at compile time:
@schema type event =
  | ProductAdded({ productId: @s.matches(DcbTag.string) string, name: string })
```

Compiles to:
```javascript
let eventSchema = S.schema(s => ({
  productId: s.m(S.string->S.Metadata.set(dcbTagId, true)),
  name: s.m(S.string)
}))
```

TypeScript has no PPX equivalent. A TypeScript user would have to write the schema
**manually** using sury's runtime API, or use a different schema library (zod, valibot)
with a bridge layer.

**Option A — sury runtime API (awkward):**
```typescript
// TypeScript user writes schema manually — no type inference, error-prone
import { S } from 'sury'
const eventSchema = S.union([
  S.object({ TAG: S.literal('ProductAdded'), productId: S.string, name: S.string })
])
```

**Option B — zod/valibot bridge:**
Define a bridge that converts zod schemas to sury schemas at runtime. TypeScript users
write familiar zod schemas; the bridge generates sury-compatible representations for
the ReScript runtime to consume. This is a significant but one-time investment.

```typescript
import { z } from 'zod'
import { tag } from '@reventless/ts-sdk'

const productAddedEvent = z.object({
  productId: tag(z.string()),  // marks as DCB tag
  name: z.string()
})
const event = z.discriminatedUnion('type', [
  z.object({ type: z.literal('ProductAdded'), ...productAddedEvent.shape }),
  z.object({ type: z.literal('ProductRenamed'), ... })
])
```

### Blocker 2: Module functors → TypeScript generics

The framework's composition pattern is ReScript module functors. The `Platform.Make(Spec)`
pattern compiles to deeply curried JavaScript:

```javascript
// What the compiled output looks like:
function Make(Spec) {
  return Behavior => EventMappings => RuntimeEnvironment => CommandTopicChannel => { ... }
}
```

In TypeScript, this maps to generic factory functions. The transformation is mechanical
but requires either:

- **Hand-written TypeScript factories** that wrap the compiled functors
- **Code-generated TypeScript classes** from the ReScript module type definitions

A TypeScript-idiomatic equivalent of `Aggregate.T` would look like:

```typescript
interface AggregateBehavior<Command, Event, Error, State> {
  resolverConfig: { commandSchema: Schema<Command>; fields: string[] }
  init(event: Event): State
  apply(state: State, event: Event): State
  create(command: Command, ctx: Context, onError: ErrorHandler<Error>): Event[]
  execute(state: State, command: Command, ctx: Context, onError: ErrorHandler<Error>): Event[]
}
```

This is expressible in TypeScript and maps cleanly to the ReScript `Behavior.T` type.

### Blocker 3: DCB tag annotations

The `@s.matches(DcbTag.string)` field annotation on entity ID fields is how the framework
identifies which fields to use as DCB tags for event filtering. This annotation is lost
in compiled output (it becomes runtime sury metadata). A TypeScript equivalent needs
to attach the same metadata:

```typescript
// TypeScript — hypothetical API
import { dcbTag } from '@reventless/ts-sdk'

interface ProductAdded {
  productId: dcbTag<string>  // marks field as DCB tag (type-level only)
  name: string
}
// At schema creation time, dcbTag wraps the schema with the metadata marker
```

### Blocker 4: No type declarations

All compiled modules expose untyped JS. The entire type system lives in `.res`/`.resi`
files that TypeScript cannot read. Generating `.d.ts` is possible (see Scenario 2) but
requires mapping ReScript abstract types and module types to TypeScript concepts, which
is not always 1:1.

---

## Does It Make Sense?

### Arguments for TypeScript support

- **Pulumi is TypeScript-native.** The infrastructure layer is already TypeScript. A
  Reventless project's composition root (the Pulumi program) would naturally be written
  in TypeScript if the framework supported it.
- **Team adoption.** Many teams are deeply invested in TypeScript. Requiring ReScript for
  business logic is a significant barrier to adoption for a framework otherwise delivering
  strong value.
- **The compiled JS is already correct.** The framework's runtime logic runs as
  JavaScript. TypeScript would call the same compiled code; only the type declarations
  are missing.
- **zod is ubiquitous.** If the schema bridge uses zod, TypeScript developers get
  excellent IDE support, runtime validation, and OpenAPI generation for free.

### Arguments against (or for caution)

- **ReScript's type system is richer.** Module types, abstract types, and first-class
  modules encode invariants that TypeScript cannot express. A TypeScript SDK would
  necessarily be a **weaker interface** — more things that are compile-time errors in
  ReScript would become runtime errors in TypeScript.
- **Maintenance burden.** Two APIs to maintain: the ReScript API and the TypeScript SDK.
  Any change to the framework must be reflected in both.
- **The PPX gap is real.** Schema generation in ReScript is magical — zero boilerplate.
  In TypeScript, even with a good bridge, it requires explicit schema declarations that
  can drift from the actual types.
- **DCB tag filtering is semantically load-bearing.** Missing a `dcbTag` annotation in
  TypeScript silently breaks query correctness. In ReScript, the PPX makes it obvious.

---

## Recommended Path

### Phase 1: GraphQL client SDK (Scenario 1) — No framework changes

Generate a typed TypeScript client from the AppSync/GraphQL schema already produced by
the framework. Use GraphQL Code Generator. This delivers TypeScript DX for command
dispatch and query reads at zero framework cost.

### Phase 2: Pulumi composition declarations (Scenario 2) — Small investment

Add `@genType` to the build pipeline and annotate the output types in `reventless-spec`:
- Add `@genType.import(("@pulumi/pulumi", "Output"))` to `Output.t` in
  `rescript-pulumi-pulumi` — this is the critical prerequisite
- Annotate `AggregateOutputs`, `ReadModelOutputs`, `PluginOutputs` and their
  transitively referenced types with `@genType`
- Add `exports` field with `types` to each published package pointing at the generated
  barrel file

Component construction (Plugin composition) stays in ReScript. TypeScript Pulumi
programs access the generated output types to wire components to other resources.
Declarations stay in sync automatically — no manual maintenance.

### Phase 3: TypeScript application SDK (Scenario 3) — Large investment

If TypeScript application code (aggregates, behaviors, projections) is required:

1. **Define the TypeScript interfaces** for `AggregateBehavior<C,E,Err,S>`,
   `ReadModelProjection<Event,State>`, `StateChangeSlice<Cmd,DecModel,Event>`, etc.
   These map directly from the ReScript module types.

2. **Build a zod-to-sury bridge** (`@reventless/schema`):
   - A `tag()` wrapper that attaches the DCB metadata to a zod schema field
   - A `toSurySchema(zodSchema)` converter that the framework uses internally

3. **TypeScript factory functions** that accept the TypeScript interfaces and call
   the compiled ReScript functors:
   ```typescript
   export function defineAggregate<C, E, Err, S>(
     spec: AggregateSpec<C, E, Err>,
     behavior: AggregateBehavior<C, E, Err, S>
   ): AggregateMaker { ... }
   ```

4. **TypeScript Platform** that wraps `ReventlessAws.Platform.Make()` and exposes
   `defineAggregate`, `defineReadModel`, etc. instead of functors.

The incremental order — Phases 1 → 2 → 3 — means each phase delivers standalone value
and informs whether the next phase is worth the investment.

---

## Risk: Schema drift in Phase 3

The single biggest ongoing risk in a TypeScript SDK is schema drift: the TypeScript
interface says one thing, the runtime serialization schema says another. In ReScript,
the compiler catches this because types and schemas are derived from the same source.
In TypeScript, they are written separately.

Mitigation: generate tests from the TypeScript schema declarations that round-trip
sample values through the sury schema. These tests catch drift at CI time.
