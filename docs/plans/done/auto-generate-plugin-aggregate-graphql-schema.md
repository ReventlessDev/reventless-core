# Plan: Auto-Generate Plugin Aggregate GraphQL Schema

## Goal

Replace the hand-written `PluginApi.res` module (which manually defines GraphQL SDL for the Plugin aggregate's types, queries, and mutations) with an automatically generated schema derived from the Plugin aggregate's sury-annotated specs — the same way every other aggregate's schema is already generated.

## Background

Every user-defined aggregate and read model in the system gets its GraphQL schema auto-generated via `GraphQL_FragmentGenerator.generate()` during `Plugin_Builder.construct()`. The Plugin aggregate is the only exception: its schema is hand-written in `PluginApi.res` and fed in as the `baseFragment` to `GraphQL_Stitcher.stitch()`.

This creates two problems:
1. **Drift risk**: If `PluginSpec.command`, `PluginReadModelSpec.state`, or related types change, `PluginApi.res` must be updated manually to match.
2. **Inconsistency**: The Plugin aggregate follows a different path than every other aggregate, making the framework harder to reason about.

## Steps

### Step 1: Extend `GraphQL_FragmentGenerator` to Support Nested Types

- [x] Add recursive type derivation: when a field's schema is `Object(...)`, generate a separate `type FieldType { ... }` and reference it by name
- [x] Support `array<Object>` → `[TypeName!]!`
- [x] Support variant schemas as GraphQL enums (e.g., `status: Connected | Disconnected | Inactive` → `enum PluginStatus { Connected Disconnected Inactive }`)
- [x] Support optional fields → nullable GraphQL types (no `!` suffix)
- [x] Collect all derived types into the fragment's `types` array

### Step 2: Add Authorization to Mutation Entries

- [x] Add optional `authorization` field to `mutationSchemaEntry` type in `Api.res`
- [x] Pass authorization through to `deriveMutationFieldFromObject` in `generate()`

### Step 3: Add Field Exclusion to Query Type Generation

- [x] Add optional `excludeFields` field to `querySchemaEntry` type in `Api.res`
- [x] When generating the object type from `stateSchema`, skip fields in the exclusion list
- [x] Use this to exclude `apiSchemaFragment`, `eventCollector`, `extensionPointNames`, `extensionNames` from the Plugin read model's GraphQL type

### Step 4: Generate the Plugin Aggregate Fragment

- [x] Create `PluginBaseFragment.res` that auto-generates the Plugin schema
- [x] Generate query entries from `PluginReadModelSpec.stateSchema` with field names `plugin`/`everyPlugin` and authorization `{group: "Admin"}`
- [x] Add manually-constructed mutations for payload-less commands (`Plugin_Activate`, `Plugin_Deactivate`)
- [x] Add plural wrapper type `Plugins` and list query `everyPlugin` (separate names for type vs field)

### Step 5: Handle the `clone` Mutation

- [x] `CoreApi.res` now exports `baseFragment` (an `apiSchemaFragment`)
- [x] The `clone` mutation is added to the base fragment alongside auto-generated Plugin mutations
- [x] `CoreApi.baseFragment` is the public API consumed by platform `Api.Make` config

### Step 6: Wire Auto-Generated Fragment into Platform

- [x] No platform changes needed — `CoreApi.baseFragment` is the same type (`apiSchemaFragment`) that platforms already consume
- [x] Both in-memory and AWS platforms receive the correct base fragment via their existing `Api.Make(Config)` pattern

### Step 7: Delete `PluginApi.res`

- [x] Removed `PluginApi.res` (no longer needed)
- [x] `CoreApi.res` simplified to only produce `baseFragment` from `PluginBaseFragment.fragment` + clone mutation

### Step 8: Verification

- [x] Build: `npm run build` — no errors, no warnings
- [x] Tests: `npm run test` — all 94 suites, 783 tests pass
- [x] Compared generated SDL with old hand-written SDL — functionally equivalent
- [x] Example projects (online-shop-aggregates, online-shop-dcb, online-shop-hybrid) build successfully

## Schema Differences (Auto-Generated vs Hand-Written)

| Aspect | Old (Hand-Written) | New (Auto-Generated) |
|--------|-------------------|---------------------|
| `status` field | `[String!]!` (incorrect) | `PluginStatus!` (proper enum) |
| Nested type names | `Extension`, `ExtensionPoint` | `PluginExtensions`, `PluginExtensionPoints` |
| `eventTopic` nullability | `String` (nullable) | `String!` (required, matches schema) |
| `id` field on Plugin type | Present (`id: ID!`) | Absent (consistent with all auto-generated read model types) |
| Mutations, queries | Identical | Identical |
| Authorization directives | Identical | Identical |

## Files Changed

| File | Change |
|------|--------|
| `reventless-infra/src/components/Api.res` | Added `authorization?` to `mutationSchemaEntry`, `excludeFields?` to `querySchemaEntry` |
| `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res` | Added recursive nested type derivation, enum support, field exclusion, authorization pass-through |
| `reventless-core/src/core/API/PluginBaseFragment.res` | **New** — auto-generates Plugin schema from sury specs |
| `reventless-core/src/core/API/CoreApi.res` | Replaced SDL strings with `baseFragment` from `PluginBaseFragment` + clone mutation |
| `reventless-core/src/core/API/PluginApi.res` | **Deleted** — replaced by auto-generation |
