# Done: `@noApi` — Opt-Out Commands from GraphQL/MCP Exposure

## Goal

Allow aggregate and StateChangeSlice command types (or individual variants) to be excluded from
automatic GraphQL mutation and MCP tool generation via a PPX annotation.

## Status: ✅ Implemented (reviewed and fixed 2026-04-08)

All 983 tests pass. Initial implementation had three PPX bugs (wrong variable
name, wrong AST node kind, `S` not in scope) and missing builder integration —
all fixed during review.

## Background

Every command in an Aggregate or StateChangeSlice is automatically exposed as a GraphQL mutation
and an MCP tool. There is currently no way to keep a command internal (e.g. system-only commands,
internal state transitions, or commands issued only by automations that should not appear in any
external API).

The mechanism involves three layers that all need to cooperate:

| Layer | File | Role |
|---|---|---|
| PPX | `packages/reventless-ppx/src/ppx/ReventlessPpx.ml` | Detects annotation, injects metadata |
| Metadata IDs | `reventless-infra/src/components/Api.res` | Typed keys for sury Metadata |
| Filtering | `reventless-core/src/components/Plugin/Plugin_Builder.res`, `Dcb/Dcb_Builder.res` | Skips entries before schema generation |

## Annotation Syntax

### Whole command type — exclude all variants

```rescript
@schema @noApi
type command =
  | InternalTransition({aggregateId: string})
  | AnotherInternal({aggregateId: string})
```

### Individual variants — exclude specific constructors

```rescript
@schema
type command =
  | PublicCommand({aggregateId: string, name: string})
  | @noApi InternalTransition({aggregateId: string})
  | @noApi AnotherInternal({aggregateId: string})
```

Both annotations can be applied to the same type; variant-level excludes are additive on top of any
type-level decision.

## Design

### Sury Metadata

Two new metadata IDs in `Api.res`:

```rescript
/** Marks an entire commandSchema as excluded from API exposure. */
let noApiId: S.Metadata.Id.t<bool> =
  S.Metadata.Id.make(~namespace="api", ~name="noApi")

/** Marks specific variant names to exclude from API exposure (variant-level opt-out). */
let noApiVariantsId: S.Metadata.Id.t<Set.t<string>> =
  S.Metadata.Id.make(~namespace="api", ~name="noApiVariants")
```

### PPX Transformation

The PPX recognises `@noApi` and strips it (so it doesn't appear in compiled output).

**Type-level**: when the attribute appears on a `@schema type command` declaration, the PPX emits
a post-binding let that wraps the generated schema:

```rescript
(* generated after  let commandSchema = ... *)
let commandSchema = ReventlessInfra.Api.markNoApi(commandSchema)
```

**Variant-level**: the PPX collects the names of annotated constructors. If any are found, it
emits an additional binding:

```rescript
(* generated after  let commandSchema = ... *)
let commandSchema =
  ReventlessInfra.Api.markNoApiVariants(commandSchema, ["InternalTransition", "AnotherInternal"])
```

Both can coexist; if `noApiId` is set to `true` the whole schema is skipped without inspecting
`noApiVariantsId`.

The helpers `markNoApi` / `markNoApiVariants` live in `reventless-infra/Api.res` (where `S` is
in scope) rather than calling `S.Metadata.set` directly in generated code (`S` is not reliably
in scope in all spec files).

The PPX change is isolated to `NoApiAnnotation.ml` and called from the main `ReventlessPpx.ml` transform.

### Filtering Utilities

Located in `ApiNoApiHelpers.res`:

```rescript
let isNoApi = (commandSchema: S.t<unknown>): bool =>
  commandSchema->S.Metadata.get(~id=ReventlessInfra.Api.noApiId)->Option.getOr(false)

let filterNoApiVariants = (fieldNames: array<string>, commandSchema: S.t<unknown>): array<string> =>
  switch commandSchema->S.Metadata.get(~id=ReventlessInfra.Api.noApiVariantsId) {
  | None => fieldNames
  | Some(excluded) => fieldNames->Array.filter(name => !(excluded->Set.has(name)))
  }
```

## Implementation Details

### Files Changed

| File | Change |
|------|--------|
| `reventless-infra/src/components/Api.res` | Added `noApiId`, `noApiVariantsId`, `markNoApi`, `markNoApiVariants` |
| `packages/reventless-ppx/src/ppx/NoApiAnnotation.ml` | New PPX helper |
| `packages/reventless-ppx/src/ppx/ReventlessPpx.ml` | Integrated NoApiAnnotation |
| `reventless-core/src/components/Api/ApiNoApiHelpers.res` | New module with helper functions |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | Uses ApiNoApiHelpers |
| `reventless-core/src/components/Plugin/Plugin_Builder.res` | Added filtering for Aggregates |
| `reventless-core/src/components/Dcb/Dcb_Builder.res` | Added filtering for StateChangeSlices |
| `reventless-core/tests/api/ApiNoApiTest.res` | Unit tests (8 tests) |

### Examples Updated

Added to `examples/online-shop-hybrid/ordering/`:

1. **Variant-level** in `Order/StateChangeSlice/CancelOrder.res`:
   - `CancelOrder` — public API
   - `ReopenOrder` — marked `@noApi` (internal)

2. **Type-level** in `Order/StateChangeSlice/RefundOrder.res`:
   - `IssueRefund` — entire command type marked `@noApi` (automation-only)

## Documentation

Updated:
- `docs/guides/reventless-ppx.md` — Added `@noApi` section
- `docs/guides/dcb-usage.md` — Added hiding commands section
- `packages/doc/docs-framework/inner-workings/mcp.md` — Mentioned `@noApi`

## Non-goals (unchanged)

- Opt-out for queries (ReadModel / StateViewSlice) — separate concern
- Runtime enforcement (auth guard) — `@noApi` is schema-time only
- OpenAPI — not yet implemented; will inherit the same `mutationEntries` when it is
