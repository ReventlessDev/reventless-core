# Backlog: Type-driven GraphQL SDL Generation from Sury Schemas

**Status:** Backlog — depends on `docs/plans/sury-alpha5-migration.md` Phase 4
**Analysis:** `docs/analysis/sury-alpha5-migration.md` (opportunity F);
exit verdict from `docs/analysis/rejected/sury-vs-effect-schema.md` §6.1.
**Companion:** `docs/plans/Backlog/api-component-openapi.md` — both
providers can consume the same converter.

## Context and motivation

`QueryDbResolvers_GraphQL.res` and `CommandGeneratorResolvers_GraphQL.res`
currently generate SDL via **hand-written string templates**:

```rescript
// QueryDbResolvers_GraphQL.res
let sdlFields = Array.concat([byIdField(name)], indexFields->Array.map(indexField(name, _)))

// CommandGeneratorResolvers_GraphQL.res
let sdlFields = fields->Array.map(field => `  ${field}(id: ID, args: String): String`)
```

Resolver return types are opaque `String` / `JSON` scalars — clients lose all
type information once it crosses the GraphQL boundary. The
`docs/analysis/rejected/sury-vs-effect-schema.md` analysis identified the
right exit:

> The path to type-driven GraphQL SDL in Reventless runs through sury's
> existing JSON Schema output, not through a library swap. Both libraries
> stop at JSON Schema / OpenAPI. However, **JSON Schema → GraphQL SDL is a
> well-supported conversion**.

`S.toJSONSchema(schema)` is present in both alpha.4 and alpha.5; this plan
does not require the alpha.5 migration, but the migration is a natural lead-in
because the same generator can serve the
`docs/plans/Backlog/api-component-openapi.md` plan with no extra work.

## Goal

Replace hand-written GraphQL SDL string templates with derivation from sury
schemas, so:
- Read-model query resolvers return strongly-typed objects matching the
  spec's `@schema type state`.
- Command mutations expose typed `Input` types matching `@schema type command`.
- The same converter feeds the OpenAPI provider (companion plan).

## What's already in place

- `S.toJSONSchema(schema)` — emits OpenAPI 3.1 / JSON Schema Draft 7 output
  per spec type. Available in alpha.4 and alpha.5.
- `Plugin_Builder` already collects `mutationSchemaEntry` and
  `querySchemaEntry` records — the unification surface from the GraphQL
  plan. Each carries the relevant sury schema.
- `pluginDefinition.apiSchemaFragment.encoded` carries the SDL fragment at
  runtime — only the *content* needs to change (string template → derived).

## Out of scope

- Custom scalars (DateTime, Json, etc.) beyond the standard GraphQL ones —
  emit as `String` initially; richer mapping is a follow-on.
- Subscription type derivation — subscriptions follow a different shape;
  see `docs/plans/graphql-subscriptions-appsync.md`.
- GraphQL federation — out of scope for v1; the derived SDL is a single
  schema per platform.

## Phases

### Phase 1 — JSON Schema → GraphQL SDL converter

**Goal:** a pure converter that takes a JSON Schema object and returns an
SDL fragment.

File: `reventless-core/src/components/Api/JSONSchemaToGraphQL.res`

```rescript
type sdlFragment = {
  types: string,       // type X { … }
  inputs: string,      // input XInput { … }
}

let toType: (~name: string, JSONSchema7.t) => string
let toInput: (~name: string, JSONSchema7.t) => string
let toFragment: (~typeName: string, ~inputName: string=?, JSONSchema7.t) => sdlFragment
```

Mapping rules (v1):
- `type: "object"` + `properties` → `type X { … }` with each property mapped
  recursively. `required` array drives `!` (non-null).
- `type: "string"` → `String`; with `format: "date-time"` → `String`
  (replace later when DateTime scalar lands).
- `type: "integer"` / `"number"` → `Int` / `Float`.
- `type: "boolean"` → `Boolean`.
- `type: "array"` + `items` → `[Item!]!` recursively.
- `oneOf` with a discriminator (TAG) → GraphQL union; emit each variant as a
  separate object type and a top-level union.
- `$ref` → reference an already-named type (assumes the referenced type is
  also being emitted in the same fragment).

Unit tests: feed the converter known sury schemas through `S.toJSONSchema`
and assert the SDL output matches expected.

### Phase 2 — Wire converter into existing resolver builders

**Goal:** swap the hand-written templates for derived SDL fragments.

Files:
- `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`
- `reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`
- `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`
  (and the equivalent CommandGenerator)

Steps:
1. For each resolver builder, look up the relevant sury schema from the
   `queryFieldNamesRegistry` / `stateSchemaRegistry` already populated by
   `Plugin_Builder` and `Platform_Admin`.
2. Call `JSONSchemaToGraphQL.toFragment` to derive types and inputs.
3. Replace the resolver field's return type from `String` / `JSON` to the
   derived type name.
4. Resolver response code (the AppSync VTL / JS templates) returns the
   DynamoDB item directly, which already matches the derived type shape
   (because both come from the same sury schema).

Validation per file:
- Existing integration tests pass.
- The resolved GraphQL schema fragment, when validated against the runtime
  AppSync schema, contains the expected typed fields.

### Phase 3 — Use derived SDL on the stitched API

**Goal:** Platform_Admin's `pluginExtensionPoint.updateApiSchema` stitches
the derived per-plugin fragments into the AppSync schema.

This is mostly a no-op: `pluginDefinition.apiSchemaFragment.encoded` already
flows through; only its contents differ. Verify the stitcher
(`GraphQL_Stitcher.stitch`) handles named-type collisions between plugins —
prefix derived types with the plugin name (e.g. `Catalog_Product` not
`Product`) to prevent clashes.

### Phase 4 — Bundle into OpenAPI provider (companion plan)

The `docs/plans/Backlog/api-component-openapi.md` plan's "schemas: each
querySchemaEntry.stateSchema generates one JSON Schema component object"
step is satisfied by the same JSON-Schema-shaped fragment Phase 1 produces.

When that plan lands, share the converter:
- GraphQL provider calls `JSONSchemaToGraphQL.toFragment`.
- OpenAPI provider calls `JSONSchemaToOpenAPI.toFragment` (much thinner —
  the input is already JSON Schema).

Both providers consume `S.toJSONSchema` output → no per-spec duplication.

## Open questions

1. **Custom scalars (DateTime, JSON, UUID).** v1 maps these to `String`.
   Follow-up: add a `~scalars` parameter to the converter that maps
   `format: "date-time"` → `DateTime`, `format: "uuid"` → `UUID`, etc., and
   ensure the AppSync schema declares them.
2. **Variant payload shape on the wire.** Sury emits
   `{TAG: "ProductAdded", ...fields}` for tagged variants. GraphQL unions
   require each variant to be a *separate* type; the resolver returns one
   of them. Need to confirm AppSync's union resolution mechanism (typename
   field) aligns with sury's TAG convention. Likely needs a small
   `__typename: tag` injection at response time.
3. **Backward compatibility of derived names.** If the derived type name
   differs from what callers currently consume (`Plugin` vs `Platform_Plugin`),
   the existing `queryFieldNamesRegistry` already covers the field-naming
   side. Type names need a similar registry or naming convention.

## Validation

- All existing `*Resolvers_GraphQL` tests pass with the converter wired in.
- An end-to-end GraphQL query against the AppSync API returns strongly-typed
  results (no more opaque `String` payloads).
- AppSync schema introspection shows expected object types for each read
  model spec.
- Stitched schema with multiple plugins resolves without name collisions.

## Risks

| Risk                                                                  | Likelihood | Impact | Mitigation                                                                       |
| --------------------------------------------------------------------- | ---------- | ------ | -------------------------------------------------------------------------------- |
| Variant union mapping differs between sury TAG and AppSync `__typename` | medium     | medium | Phase 2 verifies on a real union (PluginExtensionPointSpec command would do)     |
| Derived type name collides with hand-rolled types (admin SDL)         | medium     | medium | Plugin-prefix derived types; reserve the unprefixed namespace for admin entities |
| Performance of `S.toJSONSchema` at SDL composition time               | low        | low    | Called once per plugin per deploy / hot-reload, not per request                  |
| Hand-written SDL had assumptions the JSON Schema converter misses     | medium     | medium | Phase 2 ships per builder with rollback per file — find divergence early         |

## References

- Existing analysis: `docs/analysis/rejected/sury-vs-effect-schema.md` §6.1
- Companion: `docs/plans/Backlog/api-component-openapi.md`
- Existing GraphQL stitching: `docs/plans/Backlog/graphql-api-stitching.md`
- Sury alpha.5 migration: `docs/plans/sury-alpha5-migration.md`
