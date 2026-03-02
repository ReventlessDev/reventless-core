# Backlog: API Component — OpenAPI / REST Implementation

**Status:** Backlog — depends on `docs/plans/api-component-graphql.md` being completed first
**Analysis:** `docs/analysis/api-component-analysis.md`

## Goal

Add a second concrete `Api_Adapter.Provider` for REST APIs using OpenAPI / JSON Schema. This enables the same plugin-contributed, dynamically-stitched API surface to be exposed as a REST API (e.g. AWS API Gateway) in addition to or instead of GraphQL.

The `Api` component infrastructure (Phases 1–10 of the GraphQL plan) is fully shared. Only the protocol-specific generator, stitcher, and AWS adapter are new.

## What's already in place when this is started

After the GraphQL plan is complete:
- `Api.res` / `Api_Adapter.res` — component types and Provider interface ✓
- `mutationSchemaEntry` / `querySchemaEntry` — the two unified entry types ✓
- `Api_Builder` / `Api_Operations` — component builder and runtime wrapper ✓
- `Plugin_Builder` — already generates fragment from the two entry arrays ✓
- `pluginDefinition.apiSchemaFragment` — carries the fragment at runtime ✓
- Core connect handler calls `Api.operations.updateSchema` ✓

Only the protocol-specific parts need to be added.

## Key design decisions (from analysis)

- `schemaFragment.encoded` for OpenAPI is a JSON blob `{paths, schemas}` — different structure from the GraphQL `{types, mutations, queries}` blob but the same opaque `encoded: string` wrapper.
- **paths**: each mutation becomes a `POST` path item; each query becomes `GET` path items. Path names use lowercase kebab-case.
- **schemas**: each `querySchemaEntry.stateSchema` generates one JSON Schema component object.
- Stitching merges `paths` objects (deep merge, plugin-name prefixes prevent collisions) and `schemas` objects (same).
- Auth is via OpenAPI security scheme references embedded in each path item.

## Naming conventions

| Source | REST path (mutation) | REST path (query, single / list) | Schema component name |
|--------|---------------------|-----------------------------------|-----------------------|
| Aggregate | `POST /plugin-name/aggregate-name/cmd-name` | — | — |
| DCB StateChangeSlice | `POST /plugin-name/cmd-name` | — | — |
| ReadModel `"Product"` | — | `GET /catalog/product/{id}` / `GET /catalog/products` | `CatalogProduct` |
| StateViewSlice `"CategoriesView"` → entity `"Category"` | — | `GET /catalog/category/{id}` / `GET /catalog/categories` | `CatalogCategory` |

All path segments use lowercase kebab-case. Entity name derivation follows the same rules as GraphQL: strip "View" from StateViewSlice names, then singularize.

## Steps

### Step 1 — `OpenAPI_FragmentGenerator` in `reventless-core`

File: `reventless/reventless-core/src/components/Api/OpenAPI_FragmentGenerator.res`

Same two entry types as GraphQL generator:
```rescript
let generate: (
  ~mutationEntries: array<mutationSchemaEntry>,
  ~queryEntries: array<querySchemaEntry>,
) => Api.schemaFragment  // encoded = JSON.stringify({paths, schemas})
```

Internal structure:
```rescript
type openApiFragmentData = {
  paths: JSON.t,    // OpenAPI path item objects under /plugin-name/...
  schemas: JSON.t,  // JSON Schema component objects
}
```

Sury type mapping for JSON Schema / OpenAPI:
- `string` → `{ "type": "string" }`
- `float` → `{ "type": "number" }`
- `int` → `{ "type": "integer" }`
- `bool` → `{ "type": "boolean" }`
- `@s.matches(DcbTag.string)` → `{ "type": "string", "format": "id" }`
- Each command variant `| CmdName({fields...})` → one `POST` path with JSON body schema
- Each state record → one JSON Schema component + `GET` path returning that schema

**Tests:** Same coverage as `GraphQL_FragmentGenerator` — all four entry sources, mixed plugin, naming conventions.

### Step 2 — `OpenAPI_Stitcher` in `reventless-core`

File: `reventless/reventless-core/src/components/Api/OpenAPI_Stitcher.res`

```rescript
let stitch: (
  ~baseFragment: Api.schemaFragment,
  ~pluginFragments: array<Api.schemaFragment>,
) => JSON.t  // final OpenAPI 3.x document
```

- Decodes each fragment's `encoded` JSON → `{paths, schemas}`
- Deep-merges all `paths` objects into the root OpenAPI document's `paths`
- Deep-merges all `schemas` objects into `components/schemas`
- Base fragment (Core admin API) is always merged first
- Collision detection: duplicate path entries or schema component names are rejected with a structured error

### Step 3 — `ApiGateway_Adapter` in `reventless-aws`

File: `reventless/reventless-aws/src/components/Api/ApiGateway_Adapter.res`

Implements `Api_Adapter.Provider`:
- `type api = PulumiAws.APIGateway.RestApi.t`
- `type role = PulumiAws.IAM.Role.t`
- `makeApiResource`: creates an AWS API Gateway REST API resource using the base OpenAPI document; sets up IAM role for Lambda integrations.
- `generateFragment`: delegates to `OpenAPI_FragmentGenerator.generate`.
- `updateSchema`: calls `AwsSdk.APIGateway.putRestApi(~restApiId, ~body=stitchedJson)` after stitching with `OpenAPI_Stitcher.stitch`.

### Step 4 — In-memory REST adapter (optional)

A simple in-memory REST adapter using Node's `http` module or `express` can be added for local dev/test symmetry with the graphql-yoga adapter. This is optional — tests can use the GraphQL adapter; the REST adapter is useful only if REST-specific integration testing is needed.

If implemented, it would live at `reventless/reventless-in-memory/src/adapter/Api/REST_InMemory_Adapter.res` and use the same `OpenAPI_Stitcher` output to drive routing.

### Step 5 — Extend `Platform.T` for REST

`Platform.T` already has `module Api` after the GraphQL plan. No structural change needed — a platform that uses REST simply passes `ApiGateway_Adapter.Make(Config)` instead of `AppSync_Adapter.Make(Config)` to `Api_Builder.Make`.

If a platform needs to expose BOTH GraphQL and REST simultaneously, `Platform.T` could be extended with separate `module GraphQLApi` and `module RestApi` — but this is out of scope for v1.

### Step 6 — Examples and documentation

- Add a REST example (or extend an existing example) showing `ApiGateway_Adapter`.
- Add OpenAPI stitching section to `packages/doc/docs/inner-workings/`.
- Document path naming conventions alongside the GraphQL naming conventions.

## Files changed summary

| Package | File | Change type |
|---------|------|-------------|
| `reventless-core` | `src/components/Api/OpenAPI_FragmentGenerator.res` | New |
| `reventless-core` | `src/components/Api/OpenAPI_Stitcher.res` | New |
| `reventless-aws` | `src/components/Api/ApiGateway_Adapter.res` | New |
| `reventless-in-memory` | `src/adapter/Api/REST_InMemory_Adapter.res` | New (optional) |

All other infrastructure (entry types, `Plugin_Builder` fragment generation, Core connect handler, `Platform.T`) is shared with the GraphQL plan and requires no additional changes.

## Open questions

- **Pagination in REST:** OpenAPI pagination conventions (cursor-based vs offset) differ from the GraphQL convention (`nextToken + limit`). Decide the REST pagination pattern before implementing list path items.
- **Auth:** OpenAPI security schemes (API keys, OAuth2, Cognito User Pools via Authorizer) differ from AppSync `@aws_auth` directives. Define the `ReadModel.authorization` → OpenAPI security scheme mapping.
- **Multi-API platforms:** If a platform needs both GraphQL and REST simultaneously, `Platform.T` needs to expose both. This is intentionally deferred.
- **StateViewSlice list queries:** Deferred in the GraphQL plan (v1 generates only single-item queries). For REST, the list path `GET /catalog/categories` is more natural and should be included from the start. Resolve the list query infrastructure question before implementing this step.
