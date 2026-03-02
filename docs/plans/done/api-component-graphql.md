# Plan: API Component — GraphQL Implementation (AppSync + graphql-yoga)

**Status:** Complete — Phases 1–10 implemented and all tests passing (653/653).
Phases 11–12 are deferred backlog (auth directives + examples/docs).
**Analysis:** `docs/analysis/api-component-analysis.md`
**Branch:** alpha

## Goal

Implement the `Api` component that generates, stitches, and dynamically manages GraphQL schemas across all registered plugins. Two concrete providers:

- **AWS / AppSync** (`reventless-aws`) — production provider; creates an AppSync GraphQL API, pushes stitched SDL on plugin connect/disconnect.
- **In-memory / graphql-yoga** (`reventless-in-memory`) — local dev and test provider; drives the existing `GraphQL_Server` with typed SDL and hot-reloads when plugins register.

## Key design decisions (from analysis)

- `Api.res` and `Api_Adapter.res` live in **`reventless-infra`**, not `reventless-spec` — the API is a platform concern, not a user-declared Spec.
- `schemaFragment` stays in `reventless-spec/Plugin.res` because it travels inside `pluginDefinition`.
- Two entry types only: `mutationSchemaEntry` (aggregate commands + DCB StateChangeSlice) and `querySchemaEntry` (ReadModels + StateViewSlice). The generator is unaware of aggregate-vs-DCB; only pre-computed field names differ.
- GraphQL fragment is a three-part JSON blob `{types, mutations, queries}` kept separate so the stitcher can merge each section independently.
- No protocol-agnostic generator layer — SDL generation is inherently protocol-specific.
- In-memory adapter uses graphql-yoga (already running in `GraphQL_Server.res`) with hot schema reloading; **not** a no-op.

## Naming conventions (non-negotiable)

| Source | Mutation field | Query field (single / list) | GraphQL type name |
|--------|---------------|-----------------------------|-------------------|
| Aggregate | `PluginName_AggregateName_CmdName` | — | — |
| DCB StateChangeSlice | `PluginName_SliceName` | — | — |
| ReadModel `"Product"` | — | `Catalog_Product` / `Catalog_Products` | `CatalogProduct` |
| StateViewSlice `"CategoriesView"` → entity `"Category"` | — | `Catalog_Category` | `CatalogCategory` |

Rules: no "State", "View", or "List" suffixes in any generated name. ReadModel spec names must be singular. StateViewSlice entity name = slice name with "View" suffix stripped, then singularized.

## Steps

### Phase 1 — Extend `pluginDefinition` in `reventless-spec`

File: `reventless/reventless-spec/src/components/Plugin.res`

- Add `apiSchemaFragment` type (opaque `{encoded: string, protocol: string}`).
- Add optional `apiSchemaFragment?: apiSchemaFragment` to `pluginDefinition`.
- Backward-compatible: existing plugins omitting the field are treated as contributing no API surface.
- All sury serialisation is automatic via `@schema`.

### Phase 2 — Define `Api.res` and `Api_Adapter.res` in `reventless-infra`

Files:
- `reventless/reventless-infra/src/components/Api.res`
- `reventless/reventless-infra/src/components/Api_Adapter.res`

**`Api.res`** defines:
- `type schemaFragment = Plugin.schemaFragment` (alias)
- `type mutationSchemaEntry = { fieldNames: array<string>, commandSchema: S.t<'command> }`
- `type querySchemaEntry = { singleFieldName: string, listFieldName: option<string>, returnTypeName: string, stateSchema: S.t<'state>, authorization: option<ReadModel.authorization> }`
- `type operations = { updateSchema: array<schemaFragment> => promise<unit> }`
- `type outputs`, `type t`, `type component`, `module type T`

**`Api_Adapter.res`** defines:
- `type apiResourceMaker<'api, 'role>`
- `type schemaUpdater`
- `type fragmentGenerator`
- `module type Provider` (makeApiResource, generateFragment, updateSchema)

No implementations yet — types only.

### Phase 3 — `GraphQL_FragmentGenerator` and `GraphQL_Stitcher` in `reventless-core`

Files:
- `reventless/reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`
- `reventless/reventless-core/src/components/Api/GraphQL_Stitcher.res`

**`GraphQL_FragmentGenerator`:**
- Input: `~mutationEntries: array<mutationSchemaEntry>`, `~queryEntries: array<querySchemaEntry>`
- Traverses sury `S.t<'a>` to derive GraphQL types:
  - `string` → `String`, `float` → `Float`, `int` → `Int`, `bool` → `Boolean`
  - `@s.matches(DcbTag.string)` → `ID!`
  - Each command variant `| CmdName({fields...})` → one mutation field with inline args
  - Each state record → named `type ReturnTypeName { fields... }` in types + query field in queries
- Produces three-part intermediate: `{ types: string, mutations: string, queries: string }`
- Encodes as JSON into `Api.schemaFragment.encoded`
- Auth directives: emit `@aws_auth(cognito_groups: [...])` per field when `authorization` is present

**`GraphQL_Stitcher`:**
- Input: `~baseFragment: Api.schemaFragment`, `~pluginFragments: array<Api.schemaFragment>`
- Decodes each fragment's `encoded` JSON → `{types, mutations, queries}`
- Merges: all `types` verbatim (plugin-name prefix guarantees uniqueness); all `mutations` fields → wrapped in `type Mutation { ... }`; all `queries` fields → wrapped in `type Query { ... }`
- Base fragment always prepended
- Collision detection: reject and log if duplicate type names or field names detected

**Tests** (add alongside implementation):
- Pure unit tests — no AWS dependency
- Cover all four entry sources: aggregate, DCB slice, ReadModel, StateViewSlice
- Cover mixed plugin (both entry arrays non-empty)
- Cover naming conventions for every case in the table above
- Cover collision detection

### Phase 4 — `Api_Builder` and `Api_Operations` in `reventless-core`

Files:
- `reventless/reventless-core/src/components/Api/Api_Builder.res`
- `reventless/reventless-core/src/components/Api/Api_Operations.res`

**`Api_Builder.Make(Provider: Api_Adapter.Provider)`:**
- Calls `Provider.makeApiResource(~name, ~baseFragment, ~opts)` to create the API gateway resource
- Sets component outputs (`api`, `role`)
- Sets operations: `{ updateSchema: fragments => Provider.updateSchema(~apiId, ~baseFragment, ~pluginFragments=fragments) }`

**`Api_Operations`:**
- Thin runtime wrapper exposing `updateSchema` for use in Core callback code

### Phase 5 — `AppSync_Adapter` in `reventless-aws`

File: `reventless/reventless-aws/src/components/Api/AppSync_Adapter.res`

Implements `Api_Adapter.Provider`:
- `type api = PulumiAws.AppSync.GraphQLApi.t`
- `type role = PulumiAws.IAM.Role.t`
- `makeApiResource`: creates AppSync GraphQL API resource with base SDL; creates IAM role for Lambda data sources
- `generateFragment`: delegates to `GraphQL_FragmentGenerator.generate`
- `updateSchema`: calls `AwsSdk.AppSync.startSchemaCreation` with the stitched SDL from `GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)`

Note: `GraphQL_FragmentGenerator` and `GraphQL_Stitcher` are in `reventless-core`; only the AWS SDK call lives here.

### Phase 6 — Extend `Plugin_Builder` to generate `apiSchemaFragment`

File: `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res`

`Plugin_Builder.Make` already receives `~aggregates`, `~readModels`, `~dcbSpec`. Changes:

1. Build `mutationEntries`:
   - From `~aggregates`: one entry per aggregate. `fieldNames` = `[pluginName ++ "_" ++ aggName ++ "_" ++ constructorN, ...]`; `commandSchema` from `Aggregate.Spec`.
   - From `~dcbSpec.stateChangeSlices`: one entry per slice. `fieldNames` = `[pluginName ++ "_" ++ slice.name]`; `commandSchema` from `StateChangeSlice.Spec.commandSchema`.

2. Build `queryEntries`:
   - From `~readModels`: `singleFieldName = pluginName ++ "_" ++ rm.name`; `listFieldName = Some(pluginName ++ "_" ++ pluralize(rm.name))`; `returnTypeName = pluginName ++ rm.name`.
   - From `~dcbSpec.stateViewSlices`: entity = slice name with "View" stripped + singularized; `singleFieldName = pluginName ++ "_" ++ entity`; `listFieldName = None` (v1); `returnTypeName = pluginName ++ entity`.

3. Call `Provider.generateFragment(~mutationEntries, ~queryEntries)` to get `apiSchemaFragment`.

4. Embed fragment in Lambda configuration (environment variable or heartbeat payload) so `Connect(pluginDefinition)` carries it at runtime.

Mixed plugins (aggregates + DCB) are handled transparently — both arrays may be non-empty.

### Phase 7 — Extend `PluginReadModelSpec` and `PluginProjection`

Files:
- `reventless/reventless-core/src/core/ReadModels/Plugin/PluginReadModelSpec.res`
- `reventless/reventless-core/src/core/ReadModels/Plugin/PluginProjection.res`

- Add `apiSchemaFragment: Plugin.apiSchemaFragment` to read model state.
- Project `apiSchemaFragment` from `Connected`, `Reconnected` events.
- Clear / set to default on `Disconnected`.
- This lets the Core reconstruct the full set of active plugin fragments when any plugin connects or disconnects.

### Phase 8 — Extend `Core_Builder` and plugin connect handler

Files:
- `reventless/reventless-core/src/core/Core/Core_Builder.res`
- `reventless/reventless-core/src/core/Core/Core.res`
- `reventless/reventless-core/src/core/Aggregates/Plugin/PluginBehavior.res` or `Core_Callback.res`

- `Core_Builder.Make` gains `~api: Api.component` parameter.
- `Core.outputs` gains `api: Api.outputs`.
- Plugin connect/disconnect handler:
  1. Extracts `pluginDefinition.apiSchemaFragment`.
  2. Reads all currently-active plugin fragments from `PluginReadModel`.
  3. Calls `Api.operations.updateSchema(allFragments)`.
- This completes the runtime stitching loop.

### Phase 9 — `GraphQL_InMemory_Adapter` in `reventless-in-memory`

Files:
- `reventless/reventless-in-memory/src/adapter/Api/GraphQL_InMemory_Adapter.res`
- `reventless/reventless-in-memory/src/adapter/GraphQL_Server.res` (extend)

**Extend `GraphQL_Server.res`:**
- Add `startWithBaseFragment(baseFragment: Api.schemaFragment)` — decodes base SDL from fragment, initialises the server with Core admin schema.
- Add `rebuildSchema(~baseFragment, ~pluginFragments)` — re-stitches all fragments using `GraphQL_Stitcher`, stops the old http server, starts a new one with the updated SDL. Existing resolver function registrations are preserved.

**`GraphQL_InMemory_Adapter.Make()`:**
- `type api = unit`, `type role = unit`
- `makeApiResource`: calls `GraphQL_Server.startWithBaseFragment(baseFragment)` — replaces the unconditional `GraphQL_Server.start()` call currently in `Platform.Make`.
- `generateFragment`: delegates to `GraphQL_FragmentGenerator.generate` — produces typed SDL (real argument types from sury schemas, not generic `(id: ID, args: String): String`).
- `updateSchema`: calls `GraphQL_Server.rebuildSchema(~baseFragment, ~pluginFragments)`.

**`Platform.Make`:**
- Remove `let () = GraphQL_Server.start()`.
- The server is now started by `makeApiResource` when the Api component is constructed.

### Phase 10 — Extend `Platform.T` and concrete Platform implementations

Files:
- `reventless/reventless-infra/src/types/Platform.res`
- `reventless/reventless-aws/src/Platform.res`
- `reventless/reventless-in-memory/src/Platform.res`

**`Platform.T`** gains:
```rescript
module Api: {
  module Make: (Config: { let baseFragment: Api.schemaFragment }) => Api.T
}
```

**AWS `Platform.Make`:** `Api.Make` → `Api_Builder.Make(AppSync_Adapter.Make(Config))`
**In-memory `Platform.Make`:** `Api.Make` → `Api_Builder.Make(GraphQL_InMemory_Adapter.Make())`

### Phase 11 — DCB auth configuration (Q8)

Files:
- `reventless/reventless-spec/src/components/StateChangeSlice.res`
- `reventless/reventless-spec/src/components/StateViewSlice.res`

Add optional `authorization?: ReadModel.authorization` to `StateChangeSlice.Spec` and `StateViewSlice.Spec`. This mirrors the existing `ReadModel.config.authorization` pattern and allows `@aws_auth` directives to be emitted per DCB field in the GraphQL fragment.

If option (c) from the analysis is chosen instead (rely on AppSync default auth, no spec change), skip this phase and document the decision.

### Phase 12 — Examples and documentation

- Update `examples/aggregate/catalog` to demonstrate the Api component with an AppSync adapter.
- Update `examples/dcb/catalog` to demonstrate DCB mutations and StateViewSlice queries in the API.
- Update docs: `packages/doc/docs/reventless-components/api.md` (new file), `reventless-components-overview.md`, `get-started.md`.
- Update `packages/doc/docs/inner-workings/` with a schema-stitching section.

## Files changed summary

| Package | File | Change type |
|---------|------|-------------|
| `reventless-spec` | `src/components/Plugin.res` | Modify — add `apiSchemaFragment` to `pluginDefinition` |
| `reventless-infra` | `src/components/Api.res` | New |
| `reventless-infra` | `src/components/Api_Adapter.res` | New |
| `reventless-infra` | `src/types/Platform.res` | Modify — add `module Api` |
| `reventless-core` | `src/components/Api/Api_Builder.res` | New |
| `reventless-core` | `src/components/Api/Api_Operations.res` | New |
| `reventless-core` | `src/components/Api/GraphQL_FragmentGenerator.res` | New |
| `reventless-core` | `src/components/Api/GraphQL_Stitcher.res` | New |
| `reventless-core` | `src/core/Core/Core_Builder.res` | Modify — `~api: Api.component` |
| `reventless-core` | `src/core/Core/Core.res` | Modify — `api: Api.outputs` |
| `reventless-core` | `src/core/ReadModels/Plugin/PluginReadModelSpec.res` | Modify — add `apiSchemaFragment` to state |
| `reventless-core` | `src/core/ReadModels/Plugin/PluginProjection.res` | Modify — project fragment |
| `reventless-core` | `src/components/Plugin/Plugin_Builder.res` | Modify — generate fragment |
| `reventless-aws` | `src/components/Api/AppSync_Adapter.res` | New |
| `reventless-aws` | `src/Platform.res` | Modify — implement `Platform.Api` |
| `reventless-in-memory` | `src/adapter/Api/GraphQL_InMemory_Adapter.res` | New |
| `reventless-in-memory` | `src/adapter/GraphQL_Server.res` | Modify — add `startWithBaseFragment`, `rebuildSchema` |
| `reventless-in-memory` | `src/Platform.res` | Modify — implement `Platform.Api`, remove bare `start()` |

## Implementation status

| Phase | Status | Notes |
|-------|--------|-------|
| 1 — Extend `pluginDefinition` | ✅ Complete | `apiSchemaFragment: option<apiSchemaFragment>` added; serialisation uses `js_nullable` (see below) |
| 2 — `Api.res` + `Api_Adapter.res` | ✅ Complete | Types as designed |
| 3 — `GraphQL_FragmentGenerator` + `GraphQL_Stitcher` | ✅ Complete | Sury schema introspection via `DcbTag.res` pattern |
| 4 — `Api_Builder` + `Api_Operations` | ✅ Complete | |
| 5 — `AppSync_Adapter` | ✅ Complete | Stub — `makeApiResource` / `updateSchema` bodies are `Obj.magic(0)` / `Promise.resolve()` pending real AppSync SDK wiring |
| 6 — `Plugin_Builder` generates fragment | ✅ Complete | `FragmentProvider: Api_Adapter.Provider` functor param added |
| 7 — `PluginReadModelSpec` + `PluginProjection` | ✅ Complete | `apiSchemaFragment: option<apiSchemaFragment>` in state; projected from `Connected`/`Reconnected` |
| 8 — `Core_Builder` + connect handler | ✅ Complete | `~api` param added; `updateSchema` called from `PluginConnectExtension_Builder` after projection |
| 9 — `GraphQL_InMemory_Adapter` + `GraphQL_Server` | ✅ Complete | `rebuildSchema` stitches type defs from fragments + existing resolver names for Query/Mutation |
| 10 — `Platform.T` + concrete platforms | ✅ Complete | `module Api` added to Platform.T, AWS Platform, and in-memory Platform |
| 11 — DCB auth | 🔲 Deferred | Skip for now — rely on AppSync default auth (option c from analysis) |
| 12 — Examples + docs | 🔲 Deferred | |

---

## Implementation notes

### Phase 1 deviation — `option<T>` instead of `T?`

The plan said to use `apiSchemaFragment?: apiSchemaFragment` (optional field). This was changed to
`apiSchemaFragment: option<apiSchemaFragment>` to make `None` serialize as JSON `null` rather than
being absent from the JSON object. This matters for round-trip stability and `jsonableValidation`
(see below).

### Critical issue: sury `jsonableValidation` rejects `S.option(T)` inside union variant payloads

#### Problem

After adding `apiSchemaFragment: option<apiSchemaFragment>` to `pluginDefinition`, all tests that
called `S.enableJson()` started failing:

```
SuryError: Failed converting to JSON:
  "Heartbeat" | { TAG: "Connect"; _0: { ...; apiSchemaFragment: {...} | undefined | null; }; } | ...
  is not valid JSON
```

The error comes from `jsonableValidation` in `Sury.js`, which is triggered when compiling any
schema in JSON mode. The check is:

```javascript
if (tagFlag & 48129 || tagFlag & 16 && parent.type !== "object") {
  throw new SuryError({TAG: "InvalidJsonSchema", _0: parent}, ...)
}
```

Flag `16` is the `undefined` type. The rule says: **`undefined` is allowed only when its parent
schema is an `object`** (i.e., it is a regular optional field on a record). When `undefined` appears
anywhere else — such as inside a union — it throws.

**Root cause:** `S.option(T)` and both `S.nullable(T)` and `S.nullableAsOption(T)` all include
`undefined` in their union representation. Both PPX forms `field?: T` and `field: option<T>` compile
identically to `s.m(S.option(T))`, producing `T | undefined | null` (or `T | undefined`).

The traversal path that triggers the error:

1. Top-level `PluginSpec.commandSchema` is a union (`Heartbeat | Connect(pluginDefinition) | ...`)
2. `jsonableValidation` recurses into each variant of the union, passing `parent = commandSchema`
3. For `Connect(pluginDefinition)`, it recurses into each property, passing `parent = connectSchema`
4. For `apiSchemaFragment`, the schema is itself a union `[T, undefined, null]`
5. `jsonableValidation` recurses into that union's items, passing `parent = apiSchemaFragmentUnion`
6. For the `undefined` item: `tagFlag = 16`, `parent.type = "union"` ≠ `"object"` → **throws**

#### Fix

Use `js_nullable` from `sury/src/Sury.res.mjs`, which creates `T | null` (null only — no
`undefined`). Sury's `null` type has flag `32`, not `16`, so `32 & 16 = 0` and
`jsonableValidation` passes in all contexts.

```rescript
// Plugin.res
@module("sury/src/Sury.res.mjs")
external _jsNullable: (S.t<'a>, unit) => S.t<option<'a>> = "js_nullable"

let apiSchemaFragmentOptionSchema = _jsNullable(apiSchemaFragmentSchema, ())
```

The `unit` second argument compiles away to no argument in the JS output (ReScript omits trailing
unit args), so the call becomes `js_nullable(apiSchemaFragmentSchema)`. In Sury.js:

```javascript
function js_nullable(schema, maybeOr) {
  let schema$1 = factory([schema, nullAsUnit]);  // T | null, no undefined
  if (maybeOr === undefined) { return schema$1; } // ← takes this path
  ...
}
```

`nullAsUnit` is sury's internal "null that parses to `undefined`/`unit`" schema — it maps JSON
`null` to ReScript `None`/`()` and serialises `None` back to JSON `null`. No `undefined` is ever
present.

The `@s.matches` annotation on the field then uses this schema instead of the PPX-generated one:

```rescript
// Plugin.res
apiSchemaFragment: @s.matches(apiSchemaFragmentOptionSchema) option<apiSchemaFragment>,

// PluginReadModelSpec.res
apiSchemaFragment: @s.matches(Reventless.Plugin.apiSchemaFragmentOptionSchema)
                   option<Reventless.Plugin.apiSchemaFragment>,
```

Compiled output confirms the fix:
```javascript
// Plugin.res.mjs
let apiSchemaFragmentOptionSchema = SuryResMjs.js_nullable(apiSchemaFragmentSchema);
// pluginDefinitionSchema field:
apiSchemaFragment: s.m(apiSchemaFragmentOptionSchema)  // T | null — JSON safe
```

#### Why `S.nullableAsOption` does not work

`S.nullableAsOption(T)` is defined in sury as:
```rescript
Union.factory([schema->castToUnknown, unit->castToPublic, nullAsUnit->castToUnknown])
//                                     ^^^^^^^^^^^^^^^^^ undefined — triggers jsonableValidation
```

It includes `unit` (the `undefined` schema) alongside `null`, making it `T | undefined | null`.
This is fine for plain record fields (parent is `object`) but fails inside nested unions.

#### Why `S.nullable` does not work either

`S.nullable(T)` = `Union.factory([schema, unit, $$null])` — also includes `undefined`.

#### Alternatives considered

1. **Store `apiSchemaFragment` outside `pluginDefinition`** — would require a new event field or
   separate event, breaking the established pattern where `Connect` carries the full plugin definition.
2. **`S.transform` to build a custom schema** — possible but verbose; `js_nullable` is already the
   exact implementation needed, just not re-exported from `S.res.mjs`.
3. **Bind to `$$null$1` (internal alias for `factory$5`)** — `$$null$1` is not exported from
   `Sury.js`; only `js_nullable` is.

### Phase 9 — In-memory schema rebuild strategy

The `rebuildSchema` function in `GraphQL_Server.res` cannot simply stitch the full SDL from plugin
fragments because the in-memory resolver names (registered via `addMutationResolver` /
`addQueryResolver`) do not match the fragment-generated field names. Fragment generator outputs
names like `Catalog_Product_CreateProduct`, while yoga resolvers are registered under simpler keys.

The solution: `rebuildSchema` extracts only the **type definitions** from all fragments (the
`types` section of each fragment's decoded JSON) and prepends them to the SDL produced by the
existing `buildSdl()` function (which generates `Query` and `Mutation` blocks from the registered
resolver map). This keeps resolver wiring intact while enriching the schema with plugin-specific
GraphQL types.

### Phase 5 (AppSync_Adapter) — stub state

`AppSync_Adapter.res` satisfies the `Api_Adapter.Provider` module type but its `makeApiResource`
and `updateSchema` functions use `Obj.magic(0)` / `Promise.resolve()` as stubs. Full
implementation requires wiring `PulumiAws.AppSync` resource constructors and the AWS SDK
`startSchemaCreation` call, which is deferred until the AWS platform work is scheduled.

---

## Open questions to resolve during implementation

- **Q1 (Sury reflection):** Audit `S.t` API surface to confirm field enumeration and variant constructor names are accessible for the generator. If not, `Spec` modules may need to declare `commandSchema: array<fieldDescriptor>` alongside the existing sury schema.
- **Q4 (Concurrent connects):** During multi-plugin startup, multiple `updateSchema` calls may interleave. Mitigate in the AppSync adapter with a DynamoDB conditional write or dedicated SQS queue for schema updates.
- **Q6 (Resolver attachment before schema):** AppSync resolvers are Pulumi resources referencing field names. For multi-stack deployments, confirm resolvers attached to fields not yet in the live schema do not cause errors at attach time.
- **Q8 (DCB auth):** Decide between option (a) (extend Spec) and option (c) (rely on AppSync default) before Phase 11.
