# Plan: Move `@aws_auth` Directive Generation to AWS Package

## Goal

Remove `@aws_auth` directive generation from the provider-agnostic `reventless-core` package and move it into the AWS-specific `reventless-aws` package. Authorization metadata (`authorization` field on schema entries) stays in the core — only the AppSync-specific SDL directive rendering moves.

## Problem

Currently, `GraphQL_FragmentGenerator` (in `reventless-core`) embeds `@aws_auth(cognito_groups: ["..."])` directives directly into the generated SDL strings. This is an AWS AppSync concern leaking into provider-agnostic code. The in-memory platform has to strip these directives with a regex before passing the SDL to graphql-yoga, which is fragile and backwards.

## Current Flow

```
GraphQL_FragmentGenerator.generate()  ← embeds @aws_auth in SDL strings
    ↓
apiSchemaFragment { encoded, protocol }  ← contains @aws_auth in JSON
    ↓
GraphQL_Stitcher.stitch()  ← preserves @aws_auth verbatim
    ↓
Platform-specific:
  AppSync: pushes SDL with @aws_auth to AppSync  ✓ correct
  In-memory: strips @aws_auth with regex  ✗ wrong
```

## Desired Flow

```
GraphQL_FragmentGenerator.generate()  ← produces clean SDL (no directives)
    ↓
apiSchemaFragment { encoded, protocol }  ← clean SDL
    ↓
GraphQL_Stitcher.stitch()  ← clean SDL
    ↓
Platform-specific:
  AppSync adapter: injects @aws_auth into SDL using authorization metadata
  In-memory: uses SDL as-is  ✓ clean
```

## Files to Change

### 1. Remove `@aws_auth` from `GraphQL_FragmentGenerator.res`

**File:** `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`

Remove the `authDirective` logic from three functions:

- `deriveObjectQueryField` (lines 200-207): Remove `~authorization` parameter and `authDirective` variable. Output: `  ${singleFieldName}(id: ID!): ${typeName}`
- `deriveListQueryField` (lines 209-219): Same treatment. Output: `  ${listFieldName}(nextToken: String, limit: Int): ${pluralTypeName}!`
- `deriveMutationFieldFromObject` (lines 227-251): Same treatment. Output: `  ${fieldName}${argsPart}: String!`

The `~authorization` parameter is removed from these three functions. They become purely SDL-shape functions with no platform concerns.

### 2. Update `GraphQL_SchemaInspector.res`

**File:** `reventless-core/src/components/Api/GraphQL_SchemaInspector.res`

Remove `~authorization=None` from calls to the three functions above (lines 28, 35, 58, 65). These become simple calls without the authorization argument.

### 3. Update `generate()` in `GraphQL_FragmentGenerator.res`

**File:** `reventless-core/src/components/Api/GraphQL_FragmentGenerator.res`

In the `generate` function:
- Remove `entry.authorization` references from mutation entry processing (lines 285, 303)
- Remove `entry.authorization` references from query entry processing (lines 333, 353)
- Just call the derivation functions without `~authorization`

### 4. Remove `@aws_auth` from `PluginBaseFragment.res`

**File:** `reventless-core/src/core/API/PluginBaseFragment.res`

- Remove `adminDirective` variable and its usage on query/mutation strings
- The `adminAuth` value stays (it's used as `authorization` on schema entries, which is metadata)
- Manually constructed mutations become: `  Plugin_Activate(id: ID!): String!` (no directive)
- Manually constructed list query becomes: `  everyPlugin(nextToken: String, limit: Int): Plugins!` (no directive)

### 5. Remove `@aws_auth` from `CoreApi.res`

**File:** `reventless-core/src/core/API/CoreApi.res`

- Remove `adminDirective` and its usage on the clone mutation
- Clone mutation becomes: `  clone(restoreDateTime: String): String!`

### 6. Remove `stripAwsAuth` from in-memory `Platform.res`

**File:** `reventless-in-memory/src/Platform.res`

- Remove the `stripAwsAuth` function and `->Array.map(stripAwsAuth)` calls
- Register base fragment queries/mutations directly (no stripping needed)

### 7. Add `@aws_auth` injection in the AWS adapter

**File:** `reventless-aws/src/components/Api/AppSync_Adapter.res`

The `updateSchema` function calls `GraphQL_Stitcher.stitch(~baseFragment, ~pluginFragments)` to get the final SDL. After stitching, inject `@aws_auth` directives into the SDL for fields that have authorization.

**Approach:** The `baseFragment` carries authorization metadata via the `querySchemaEntry.authorization` field. But after stitching, we only have a plain SDL string — the authorization metadata is lost.

**Two options:**

**Option A — Post-process SDL in `updateSchema`:** Parse field names from the stitched SDL and inject `@aws_auth` based on a known mapping. This is fragile — it requires knowing which fields need auth.

**Option B — Inject before stitching:** Override `generateFragment` in the AppSync adapter to post-process the fragment before it's stored. Add `@aws_auth` directives to the SDL strings inside the fragment's encoded JSON, using the authorization data from the entries.

**Recommended: Option B.** The `AppSync_Adapter.generateFragment` function already calls `GraphQL_FragmentGenerator.generate`. After that call, decode the fragment, augment SDL strings with `@aws_auth` based on the authorization from entries, and re-encode.

For the base fragment (Plugin aggregate), the authorization metadata is on `CoreApi.baseFragment`'s entries. We'd need to either:
- Store authorization metadata alongside the fragment (new field), or
- Have the AppSync adapter augment the base fragment before passing it to `Api_Builder`

**Simplest approach:** Add a utility function `injectAwsAuth` in the AWS package that takes authorization entries and a fragment, and returns a new fragment with `@aws_auth` injected into the SDL. The AppSync adapter calls this in both `generateFragment` and when processing the base fragment.

### 8. Pass authorization metadata to the AppSync adapter

The `generateFragment` function receives `~mutationEntries` and `~queryEntries` which already carry `authorization` data. The AppSync adapter's `generateFragment` can:

1. Call `GraphQL_FragmentGenerator.generate(~mutationEntries, ~queryEntries)` to get the clean fragment
2. Iterate over entries, match field names to SDL strings in the fragment, and inject `@aws_auth`
3. Return the augmented fragment

For the base fragment, `CoreApi.baseFragment` is already a finished fragment. The AppSync platform's `Api.Make(Config)` receives it. The adapter's `updateSchema` can augment it before stitching.

## Verification

- [x] Build: `npm run build` — no errors, no warnings
- [x] Tests: `npm run test` — all 783 pass
- [x] In-memory: no `@aws_auth` in any SDL (no stripping needed)
- [x] AWS adapter: `@aws_auth` directives present in stitched SDL for fields with authorization
- [ ] Run DCB example: pre-existing Component.js ESM resolution issue prevents runtime start (unrelated to this change)

## Risks

- **SDL field matching:** Injecting `@aws_auth` by matching field names in SDL strings is somewhat fragile. If field formatting changes, the injection could miss. Mitigate by using the same `extractLeadingName` utility from `GraphQL_Stitcher`.
- **Base fragment augmentation:** The base fragment is created at module init time. The AWS adapter needs to augment it, which means the augmentation happens at module init too (not lazily). This should be fine since it's just string manipulation.
- **Authorization on user plugins:** Currently user plugin entries pass `authorization: None`, so no `@aws_auth` is generated for them. This stays the same — only entries with `Some(authorization)` get directives.
