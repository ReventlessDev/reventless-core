# Plan: Schema Generation Cleanup

**Status:** Steps 1–7, 9 complete. Step 8 deferred.
**Analysis:** `docs/analysis/done/schema-generation-review.md`
**Related:** `docs/plans/Backlog/api-component-openapi.md` (OpenAPI integration depends on this cleanup)

## Goal

Eliminate duplication, centralize naming conventions, and clean up the schema generation pipeline for GraphQL and MCP. This prepares the codebase for adding OpenAPI as a third protocol without tripling the existing duplication.

## Steps

### Step 1 — Create `Api_Naming.res` ✅

File: `reventless/reventless-core/src/components/Api/Api_Naming.res`

Extracted naming helpers from `Plugin_Builder.construct()` into a dedicated module:

- `pluralize`, `singularize`, `stripViewSuffix` — string helpers
- `aggregateMutationField`, `sliceMutationField` — mutation field naming
- `queryFieldNamesForReadModel`, `queryFieldNamesForStateView`, `queryFieldNamesForSliceQueryDb` — query field naming returning `queryNames` record
- `coreField` — `Core_` prefix for core operations

Updated `Plugin_Builder.construct()`, `PluginBaseFragment.res`, and `CoreApi.res` to use `Api_Naming`.

Unified `Plugin_Helpers.queryFieldNames` type with `Api_Naming.queryNames`.

**Note:** `toKebabCase` deferred until OpenAPI implementation.

**Files changed:**
- `reventless-core/src/components/Api/Api_Naming.res` — New
- `reventless-core/src/components/Plugin/Plugin_Builder.res` — Replace all inline naming with Api_Naming calls
- `reventless-core/src/components/Plugin/Plugin_Helpers.res` — Use `Api_Naming.queryNames` type for registry
- `reventless-core/src/core/API/PluginBaseFragment.res` — Use `Api_Naming.coreField`
- `reventless-core/src/core/API/CoreApi.res` — Use `Api_Naming.coreField`

### Step 2 — Clean up SuryToJsonSchema ✅

Removed `deriveVariantSchema` (identical to `deriveObjectSchema`). Updated `MCP_SchemaGenerator.res` to call `deriveObjectSchema` instead.

**Files changed:**
- `reventless-core/src/components/Api/SuryToJsonSchema.res` — Remove `deriveVariantSchema`
- `reventless-core/src/components/Api/MCP_SchemaGenerator.res` — Call `deriveObjectSchema` instead

### Step 3 — Clean up GraphQL_FragmentGenerator ✅

Removed `deriveObjectType` (flat, superseded by `deriveObjectTypeWithNested`) and `deriveScalarType`. Updated `GraphQL_SchemaInspector.res` to use `deriveFieldType` and `deriveObjectTypeWithNested`. Updated `deriveMutationFieldFromObject` to use `deriveFieldType(~required=true)` for consistent required args.

**Files changed:**
- `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` — Remove dead code, unify type derivation
- `reventless-core/src/components/Api/GraphQL_SchemaInspector.res` — Use deep variants
- `reventless-in-memory/tests/adapter/GraphQL_SchemaInspectorTest.res` — Update `inspectScalar` test for consistent nullable behavior

### Step 4 — Extract shared `SchemaType` from sury schemas ✅

Created `SchemaType.res` with shared intermediate representation (`schemaType` variant type). Both protocol generators now use `SchemaType.fromSury` / `SchemaType.fromSuryObject` as the single place for sury introspection, then map to their output format:

- `GraphQL_FragmentGenerator.fromSchemaType` — `schemaType => string` (SDL type reference)
- `SuryToJsonSchema.fromSchemaType` — `schemaType => JSON.t` (JSON Schema object)

**Files changed:**
- `reventless-core/src/components/Api/SchemaType.res` — New
- `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` — Refactor to use SchemaType
- `reventless-core/src/components/Api/SuryToJsonSchema.res` — Refactor to use SchemaType

### Step 5 — Add `GraphQL_Stitcher.encode` ✅

Added `encode` function as inverse of `decode`. Updated `PluginBaseFragment.res` and `CoreApi.res` to use `encode` instead of manual JSON construction.

**Files changed:**
- `reventless-core/src/components/Api/GraphQL_Stitcher.res` — Add `encode`
- `reventless-core/src/core/API/PluginBaseFragment.res` — Use `encode`
- `reventless-core/src/core/API/CoreApi.res` — Use `encode`

### Step 6 — Expose QueryDb names from slice builders ✅

Added `queryDbName` to `AutomationSlice.T`, `OutboundTranslationSlice.T`, and `InboundTranslationSlice.T` module types. Each builder exposes `queryDbName = Spec.name ++ "Todo"` (or `"Audit"` for Inbound). `Plugin_Builder` now references `A.queryDbName`, `O.queryDbName`, `I.queryDbName` instead of hardcoding suffixes.

**Files changed:**
- `reventless-core/src/components/AutomationSlice/AutomationSlice.res` — Add `queryDbName` to module type T
- `reventless-core/src/components/AutomationSlice/AutomationSlice_Builder.res` — Expose `queryDbName`
- `reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice.res` — Add `queryDbName` to module type T
- `reventless-core/src/components/OutboundTranslationSlice/OutboundTranslationSlice_Builder.res` — Expose `queryDbName`
- `reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice.res` — Add `queryDbName` to module type T
- `reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res` — Expose `queryDbName`
- `reventless-core/src/components/Plugin/Plugin_Builder.res` — Use exposed names

### Step 7 — Make Core operations protocol-agnostic ✅

Core mutations (Activate, Deactivate, Clone) now flow through the same entry-based pipeline as plugin mutations. Each operation has a sury `@schema` arg type, making it a standard `mutationSchemaEntry`. The GraphQL fragment and MCP tools are generated from entries — no more hand-built SDL strings or manual JSON Schema objects.

- `PluginBaseFragment.res` — defines `@schema type activateArgs` and `deactivateArgs` with sury schemas, exports `mutationEntries` and `queryEntries`
- `CoreApi.res` — defines `@schema type cloneArgs`, combines all Core mutation entries (`PluginBaseFragment.mutationEntries ++ [cloneEntry]`), generates `baseFragment` purely from `GraphQL_FragmentGenerator.generate`
- `Platform.res` (in-memory) — replaced 63 lines of hand-built `MCP_Server.registerTool` calls with a single `MCP_Server.registerToolsFromEntries(~pluginName="Core", ~mutationEntries=CoreApi.mutationEntries, ...)` call

**Files changed:**
- `reventless-core/src/core/API/PluginBaseFragment.res` — Add sury arg schemas, export entry arrays
- `reventless-core/src/core/API/CoreApi.res` — Combine entries, generate fragment from entries
- `reventless-in-memory/src/Platform.res` — Replace hand-built MCP registrations with `registerToolsFromEntries`

### Step 8 — Replace mutable hooks with explicit parameters (deferred)

Refactor the registration hooks in `Plugin_Helpers.res` from global mutable state to explicit parameters. This is a high-impact architectural change that touches the platform adapter interface (`Api_Adapter.Provider`), all platform implementations (`Platform.res`, AWS adapters), and the Plugin_Builder functor signature.

**Reason for deferral:** High risk of breaking the AWS platform adapter (untestable locally). The hooks work correctly now and the other cleanup steps already eliminate the main sources of duplication. This step should be done as a separate focused effort with AWS integration testing.

### Step 9 — Update `eventLogSchemaEntry` TSDoc ✅

Updated TSDoc on entry types in `Api.res` to reflect all planned consumers: MCP, GraphQL, and (future) OpenAPI/REST.

**Files changed:**
- `reventless-infra/src/components/Api.res` — Update TSDoc

## Deferred

- **Structured names in entries** (Issue 7 from analysis) — Storing `{plugin, component, operation}` instead of flat strings in `mutationSchemaEntry.fieldNames`. High effort, consider when implementing OpenAPI.
- **Step 8** — See individual step notes above.
- **Api_Naming unit tests** — The naming functions are exercised indirectly through 236 existing integration tests. Dedicated unit tests can be added when `toKebabCase` (OpenAPI) is implemented.

## Files changed summary

| Package | Files | Steps |
|---------|-------|-------|
| `reventless-core` | `Api_Naming.res` (new), `SchemaType.res` (new), `GraphQL_FragmentGenerator.res`, `GraphQL_Stitcher.res`, `GraphQL_SchemaInspector.res`, `SuryToJsonSchema.res`, `MCP_SchemaGenerator.res`, `Plugin_Builder.res`, `Plugin_Helpers.res`, `PluginBaseFragment.res`, `CoreApi.res`, `AutomationSlice.res`, `AutomationSlice_Builder.res`, `OutboundTranslationSlice.res`, `OutboundTranslationSlice_Builder.res`, `InboundTranslationSlice.res`, `InboundTranslationSlice_Builder.res` | 1–7, 9 |
| `reventless-infra` | `Api.res` | 9 |
| `reventless-in-memory` | `GraphQL_SchemaInspectorTest.res`, `Platform.res` | 3, 7 |
