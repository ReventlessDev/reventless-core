# Analysis: Schema Generation for GraphQL, MCP, and OpenAPI

**Date:** 2025-03-12
**Scope:** Review of schema generation across all three API protocols for duplication, naming consistency, and centralization opportunities.

## Architecture Overview

The schema generation pipeline has three phases:

1. **Entry collection** — `Plugin_Builder.construct()` builds `mutationSchemaEntry[]`, `querySchemaEntry[]`, and `eventLogSchemaEntry[]` from aggregate commands, DCB slices, read models, etc.
2. **Protocol-specific generation** — Each protocol converts entries into its own schema format (GraphQL SDL fragments, MCP tool/resource definitions, or OpenAPI paths/schemas).
3. **Stitching** — Protocol-specific stitchers merge base + plugin fragments into a final schema.

The entry types in `ReventlessInfra.Api` are shared across all protocols. This is the correct foundation.

## Files Involved

| File | Purpose |
|------|---------|
| `reventless-infra/src/components/Api.res` | Shared entry types (`mutationSchemaEntry`, `querySchemaEntry`, `eventLogSchemaEntry`) |
| `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` | Sury → GraphQL SDL |
| `reventless-core/src/components/Api/GraphQL_Stitcher.res` | Merge SDL fragments |
| `reventless-core/src/components/Api/MCP_SchemaGenerator.res` | Sury → MCP tool/resource definitions |
| `reventless-core/src/components/Api/SuryToJsonSchema.res` | Sury → JSON Schema (shared utility) |
| `reventless-core/src/components/Plugin/Plugin_Builder.res` | Entry collection + naming construction |
| `reventless-core/src/components/Plugin/Plugin_Helpers.res` | Registries + hooks for runtime binding |
| `reventless-core/src/core/API/PluginBaseFragment.res` | Core Plugin query/mutation fragment |
| `reventless-core/src/core/API/CoreApi.res` | Core_Clone mutation, base fragment assembly |
| `reventless-in-memory/src/adapter/MCP_Server.res` | In-memory MCP server runtime |
| `reventless-aws/src/adapter/Mcp/MCP_Lambda.res` | AWS MCP Lambda handler |
| `reventless-infra/src/components/Api_Adapter.res` | Provider module type (generateFragment, updateSchema) |

---

## Issue 1: Duplicated Sury-to-Schema Conversion Logic

**Severity: High**

`GraphQL_FragmentGenerator.res` and `SuryToJsonSchema.res` both walk sury `S.t<unknown>` schemas to derive type information, but they do so independently with duplicated pattern matching:

| Concern | GraphQL_FragmentGenerator | SuryToJsonSchema |
|---------|--------------------------|------------------|
| String detection | `String(_) => "String!"` | `String(_) => {type: "string"}` |
| Number detection | `Number(_) => "Float!"` | `Number(_) => {type: "number"}` |
| Boolean detection | `Boolean(_) => "Boolean!"` | `Boolean(_) => {type: "boolean"}` |
| ID detection | `isTagged(s) => "ID!"` | `isTagged(s) => {type: "string", format: "uuid"}` |
| TAG filtering | Manual `argName !== "TAG"` check | Manual `fieldName !== "TAG"` check |
| Object recursion | `deriveObjectTypeDeep` | `deriveObjectSchema` |
| Union handling | Null-check + enum detection | `oneOf` array |
| Array handling | `Array({additionalItems})` pattern | `Array({items})` pattern |

**Additionally**, `SuryToJsonSchema.deriveVariantSchema` and `SuryToJsonSchema.deriveObjectSchema` are nearly identical — both iterate object properties, filter TAG, build properties dict + required array. The only difference is that `deriveVariantSchema` is documented as "for a single variant" but structurally does the same thing as `deriveObjectSchema`.

**Recommendation:** Extract a shared **intermediate representation** from sury schemas:

```rescript
type rec schemaType =
  | ScalarString
  | ScalarNumber
  | ScalarBoolean
  | ScalarBigInt
  | EntityId
  | Nullable(schemaType)
  | ArrayOf(schemaType)
  | ObjectRef(string, dict<schemaType>)
  | Enum(string, array<string>)
  | Unknown

let fromSury: (~parentName: string, ~fieldName: string, S.t<unknown>) => schemaType
```

Then each protocol maps `schemaType` to its output format — GraphQL SDL strings, JSON Schema objects, or OpenAPI schema components. This eliminates all duplicated sury pattern matching.

---

## Issue 2: Naming Convention Logic Is Not Centralized

**Severity: High**

Field names for queries and mutations are constructed in `Plugin_Builder.construct()` using inline string interpolation with local helper functions:

```rescript
// Line 56-66 — local functions inside construct()
let pluralize = (n: string) => n->String.endsWith("s") ? n : n ++ "s"
let stripViewSuffix = (n: string) => ...
let singularize = (n: string) => ...
```

These helpers are:
- **Not exported** — cannot be reused by OpenAPI_FragmentGenerator or any other consumer
- **Not testable** in isolation
- **Duplicated conceptually** — the OpenAPI backlog plan says "All path segments use lowercase kebab-case. Entity name derivation follows the same rules as GraphQL: strip 'View' from StateViewSlice names, then singularize." This means OpenAPI will need the same `singularize`/`stripViewSuffix` logic plus a `toKebabCase` transform.

**Field name patterns scattered across Plugin_Builder:**

| Component | Mutation field name | Query single | Query list | Return type |
|-----------|-------------------|--------------|------------|-------------|
| Aggregate | `${plugin}_${aggr}_${cmd}` | — | — | — |
| StateChangeSlice | `${plugin}_${slice}` | — | — | — |
| InboundTranslationSlice | `${plugin}_${slice}` | — | — | — |
| ReadModel | — | `${plugin}_${singular(name)}` | `${plugin}_${plural(name)}` | `${plugin}_${singular(name)}` |
| StateViewSlice | — | `${plugin}_${singular(stripView(name))}` | `${plugin}_${plural(stripView(name))}` | `${plugin}_${singular(stripView(name))}` |
| AutomationSlice | — | `${plugin}_${name}Todo` | `${plugin}_${name}Todos` | `${plugin}_${name}Todo` |
| OutboundTranslation | — | `${plugin}_${name}Todo` | `${plugin}_${name}Todos` | `${plugin}_${name}Todo` |
| InboundTranslation | — | `${plugin}_${name}Audit` | `${plugin}_${name}Audits` | `${plugin}_${name}Audit` |

Core-level names use a different pattern (`Core_Plugin`, `Core_Plugins`, `Core_Clone`, `Core_Plugin_Activate`) defined directly in `PluginBaseFragment.res` and `CoreApi.res`.

**Recommendation:** Create `Api_Naming.res` as a centralized naming module:

```rescript
// reventless-core/src/components/Api/Api_Naming.res

let pluralize: string => string
let singularize: string => string
let stripViewSuffix: string => string
let toKebabCase: string => string  // for OpenAPI

// Centralized field name constructors
let aggregateMutationField: (~plugin: string, ~aggregate: string, ~command: string) => string
let sliceMutationField: (~plugin: string, ~slice: string) => string
let queryFieldNames: (~plugin: string, ~name: string) => {single: string, list: string, returnType: string}
let stateViewQueryFieldNames: (~plugin: string, ~viewName: string) => {single: string, list: string, returnType: string}
let automationQueryFieldNames: (~plugin: string, ~name: string) => {single: string, list: string, returnType: string}
let coreField: (~name: string) => string  // "Core_" prefix
```

---

## Issue 3: `deriveVariantSchema` ≈ `deriveObjectSchema` in SuryToJsonSchema

**Severity: Medium**

`SuryToJsonSchema.deriveVariantSchema` (lines 71-93) and `SuryToJsonSchema.deriveObjectSchema` (lines 43-65) are nearly identical functions. Both:
1. Match on `Object({properties})`
2. Filter out "TAG" field
3. Build `{type: "object", properties: {...}, required: [...]}` JSON

The only difference is the function name. `deriveVariantSchema` could be replaced with a call to `deriveObjectSchema`.

**Recommendation:** Remove `deriveVariantSchema` and use `deriveObjectSchema` everywhere. If the distinction matters for documentation, add a comment or type alias.

---

## Issue 4: GraphQL `deriveObjectType` (flat) Is Dead Code

**Severity: Low**

`GraphQL_FragmentGenerator.deriveObjectType` (lines 140-153) uses `deriveScalarType` and only handles flat scalar fields. It was superseded by `deriveObjectTypeWithNested` (lines 160-186) which handles nested types, enums, and arrays. The flat version appears unused in the current codebase.

**Recommendation:** Verify no callers exist and remove `deriveObjectType`.

---

## Issue 5: `deriveScalarType` Inconsistency with `deriveFieldType`

**Severity: Medium**

`GraphQL_FragmentGenerator` has two overlapping type derivation functions:

- `deriveScalarType` (lines 120-132) — returns `"String"`, `"Float"`, `"Boolean"` (no `!` suffix for non-ID fields)
- `deriveFieldType` (lines 18-89) — returns `"String!"`, `"Float!"`, `"Boolean!"` (with required `!` suffix)

`deriveScalarType` is used by `deriveMutationFieldFromObject` for mutation arguments, meaning **mutation arguments are nullable** while **query return fields are non-nullable**. This may be intentional (GraphQL best practice: nullable inputs, non-null outputs), but the two functions duplicate the same sury-to-GraphQL mapping with different nullability rules. This is fragile — adding a new scalar type requires updating both functions.

**Recommendation:** Unify into one function with a `~required: bool` parameter (which `deriveFieldType` already has) and use it everywhere.

---

## Issue 6: Core Fragment Generation Bypasses the Provider Abstraction

**Severity: Medium**

`PluginBaseFragment.res` and `CoreApi.res` call `GraphQL_FragmentGenerator.generate` directly and produce fragments with `protocol: "graphql"`. This means:

1. The Core API (Plugin CRUD, Clone) is **GraphQL-only** — no MCP tools are generated for Core operations.
2. When OpenAPI is added, Core operations won't get REST paths either.
3. The `Api_Adapter.Provider.generateFragment` abstraction exists but is only used for plugin-level fragments, not Core-level ones.

**Recommendation:** Make Core operations protocol-agnostic by:
- Generating `mutationSchemaEntry` / `querySchemaEntry` for Core operations
- Passing them through the same `FragmentProvider.generateFragment` call
- Registering them with the MCP hook just like plugin entries

---

## Issue 7: MCP Tool Names vs GraphQL Field Names — Same Names, Different Protocols

**Severity: Low (but important for OpenAPI)**

Currently MCP tool names and GraphQL mutation/query field names are identical (e.g., `Catalog_Product_AddProduct`). This is good for consistency. However:

- MCP tools use the field name directly as the tool name
- GraphQL uses it as the SDL field identifier
- OpenAPI (per backlog plan) will use lowercase kebab-case paths: `POST /catalog/product/add-product`

This means the **same naming source** (entries from Plugin_Builder) will need to be transformed differently per protocol. Currently the name is baked into `mutationSchemaEntry.fieldNames` as the final form, which works for GraphQL and MCP but won't work for OpenAPI without a `toKebabCase` transform.

**Recommendation:** Store a structured name in entries (e.g., `{plugin: "Catalog", component: "Product", operation: "AddProduct"}`) and let each protocol formatter construct its own surface name. This is a bigger refactor but would make naming truly centralizable.

---

## Issue 8: `eventLogSchemaEntry` TSDoc Is Too Narrow

**Severity: Low**

The `eventLogSchemaEntry` type and its collection in Plugin_Builder (lines 492-510) currently serve MCP event history resources only. However, event logs will be consumed by multiple protocols in the future:

- **MCP** — already implemented as event history resources
- **GraphQL** — planned: event log subscriptions in a later phase
- **OpenAPI** — likely: event history REST endpoints

The entry type itself is protocol-agnostic, which is correct. But the TSDoc says "Used by MCP to expose event history as resources," which understates its role.

**Recommendation:** Update the TSDoc to reflect all planned consumers: "Used by protocol generators to expose event history (e.g., MCP resources, GraphQL subscriptions, REST endpoints)." Also ensure the `eventLogSchemaEntry` carries enough information for GraphQL subscription generation (e.g., subscription field naming) — this may require adding fields to the entry type when subscriptions are implemented.

---

## Issue 9: Automation/Outbound "Todo" and Inbound "Audit" Suffixes Are Duplicated

**Severity: Medium**

In Plugin_Builder lines 447-481, the suffixes `"Todo"` and `"Audit"` are hardcoded:

```rescript
let todoName = A.Spec.name ++ "Todo"      // AutomationSlice
let todoName = O.Spec.name ++ "Todo"      // OutboundTranslationSlice
let auditName = I.Spec.name ++ "Audit"    // InboundTranslationSlice
```

These same suffixes are already defined in the respective `_Builder` modules where the QueryDb is created:
- `AutomationSlice_Builder.res` line 34: `let name = Spec.name ++ "Todo"`
- `OutboundTranslationSlice_Builder.res` line 36: `let name = Spec.name ++ "Todo"`
- `InboundTranslationSlice_Builder.res` line 29: `let name = Spec.name ++ "Audit"`

Plugin_Builder duplicates these suffixes instead of deriving the QueryDb name from the builder's actual spec. If the suffix ever changes in a builder, Plugin_Builder would silently generate mismatched query field names.

**Recommendation:** Expose the QueryDb name from each slice builder (or its outputs) so Plugin_Builder can reference it directly rather than reconstructing it with a hardcoded suffix.

---

## Issue 10: `PluginBaseFragment.res` Manually Constructs Encoded JSON

**Severity: Low**

Both `PluginBaseFragment.res` and `CoreApi.res` manually construct the `{types, mutations, queries}` JSON blob by decoding, modifying, and re-encoding:

```rescript
let parts = GraphQL_Stitcher.decode(typesAndQueries)
let encoded = JSON.Encode.object(Dict.fromArray([
  ("types", ...),
  ("mutations", ...),
  ("queries", ...),
]))
```

This encoding format is an implicit contract between `GraphQL_FragmentGenerator.generate`, `GraphQL_Stitcher.decode`, and these manual constructions. If the format changes, all three places need updating.

**Recommendation:** Add an `encode` function to `GraphQL_Stitcher` as the inverse of `decode`:

```rescript
let encode: fragmentParts => Reventless.Plugin.apiSchemaFragment
```

---

## Issue 11: Hook-Based Registration Is Protocol-Specific

**Severity: Medium**

`Plugin_Helpers.res` has separate hooks for different purposes:

- `schemaTypeRegistrationHook` — GraphQL types (in-memory only)
- `aggregateMutationResolverHook` — GraphQL aggregate mutations (in-memory only)
- `dcbMutationResolverHook` — GraphQL DCB mutations (in-memory only)
- `inboundMutationResolverHook` — GraphQL inbound mutations (in-memory only)
- `mcpSchemaRegistrationHook` — MCP tools/resources (in-memory only)

When OpenAPI is added, another hook will be needed. This proliferation of protocol-specific hooks is a sign that the registration model should be generalized.

**Recommendation:** The underlying problem is that these hooks are global mutable state (`ref<option<...>>`) used to work around the fact that `Plugin_Builder` doesn't have direct access to the platform's registration capabilities. Each hook is set by the platform before plugins are built and is `None` on platforms that don't need it (e.g., AWS).

Rather than consolidating into fewer mutable hooks, the registration callbacks should be passed explicitly — either through the `Api_Adapter.Provider` module type or as parameters to `Plugin_Builder.construct()`. This eliminates the global mutable state, makes dependencies explicit, and naturally supports multiple protocols without adding new hooks per protocol.

---

## Summary: Priority Matrix

| # | Issue | Severity | Effort | OpenAPI Impact |
|---|-------|----------|--------|----------------|
| 1 | Duplicated sury-to-schema conversion | High | Medium | Triples the duplication |
| 2 | Naming not centralized | High | Low | Blocks clean OpenAPI naming |
| 3 | deriveVariantSchema ≈ deriveObjectSchema | Medium | Trivial | Minor |
| 4 | Dead deriveObjectType function | Low | Trivial | None |
| 5 | deriveScalarType vs deriveFieldType overlap | Medium | Low | Doubles again for OpenAPI |
| 6 | Core fragment bypasses Provider | Medium | Medium | Core ops missing from REST/MCP |
| 7 | Flat string names vs structured names | Low | High | Requires transform for kebab-case |
| 8 | eventLogSchemaEntry TSDoc misleading | Low | Trivial | None |
| 9 | Duplicated Todo/Audit suffixes | Medium | Low | Must centralize for 3 protocols |
| 10 | Manual fragment JSON encoding | Low | Low | Another place to manually encode |
| 11 | Protocol-specific hook proliferation | Medium | Medium | Another hook needed |

## Recommended Action Order

1. **Issue 2** — Create `Api_Naming.res` (low effort, high impact, prerequisite for OpenAPI)
2. **Issues 3, 4, 5** — Clean up SuryToJsonSchema and GraphQL_FragmentGenerator (quick wins)
3. **Issue 1** — Extract shared `schemaType` from sury schemas (medium effort, prevents OpenAPI duplication)
4. **Issue 10** — Add `GraphQL_Stitcher.encode` (quick win, reduces fragility)
5. **Issue 6** — Make Core operations protocol-agnostic (enables MCP/REST for admin)
6. **Issue 9** — Expose QueryDb names from slice builders instead of duplicating suffixes (quick)
7. **Issue 11** — Consolidate hooks (medium effort, cleaner architecture)
8. **Issue 7** — Structured names (high effort, consider for v2)
