# DCB Query Resolvers & APPSYNC_JS Migration Fixes

## Context

Deploying the first plugin with StateViewSlice-only DCB components on AWS revealed three core issues:

1. AppSync query resolvers are never created for DCB StateViewSlice/InboundTranslation QueryDbs
2. AppSync resolver JS code uses VTL-era utility functions that are invalid in APPSYNC_JS runtime
3. `Plugin.make` signature changed (removed `~api`, `~apiRole`, `~scheduler`) — downstream consumers need awareness

---

## Status

| Step | Description | Status |
|------|-------------|--------|
| 1 | Merge DCB QueryDbs into allQueryDbs for resolver creation | done |
| 2 | Replace VTL util functions with JS equivalents in AppSync_Resolver_Functions | done |
| 3 | Validate — rebuild core and run existing tests | done |
| 4 | Publish core packages | not started |

---

## Step 1 — Merge DCB QueryDbs into allQueryDbs

**File:** `reventless/reventless-core/src/components/Plugin/Plugin_Builder.res`

**Problem:** `allQueryDbs` (line 167) is populated only from `readModelsOutputs->ReadModel.allQueryDbs`. DCB StateViewSlice and InboundTranslationSlice QueryDbs are never included. This means `createResolvers` (line 434) never creates AppSync resolvers for them.

**Fix:** After line 167, merge DCB QueryDbs into `allQueryDbs`:

```rescript
let readModelsOutputs = readModels->createReadModels(~api, ~apiRole, allEventTopics, opts)
let allQueryDbs = readModelsOutputs->ReadModel.allQueryDbs
// Merge DCB StateViewSlice and InboundTranslation QueryDbs into
// allQueryDbs so createResolvers builds AppSync resolvers for them too.
dcbResult.stateViewSlicesOutputs
->Dict.toArray
->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
dcbResult.inboundTranslationSlicesOutputs
->Dict.toArray
->Array.forEach(((k, v)) => allQueryDbs->Dict.set(k, v.queryDb))
let queryEngine = QueryEngineAdapter.make(allQueryDbs)
```

**Impact:** All plugins with DCB StateViewSlices will now get AppSync query resolvers automatically. No breaking changes — plugins without StateViewSlices are unaffected (empty dict, no-op forEach).

**Already applied locally** — verify with `grep "Dict.toArray" Plugin_Builder.res`.

---

## Step 2 — Replace VTL util functions in APPSYNC_JS resolver code

**File:** `rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res`

**Problem:** The resolver JS code templates use VTL-era `$util` functions that don't exist in the APPSYNC_JS runtime:

- `util.defaultIfNull(x, default)` — invalid, causes `INVALID_FUNCTION_INVOCATION`
- `util.defaultIfNullOrBlank(x, default)` — invalid
- `util.isNull(x)` — invalid
- `util.isNullOrBlank(x)` — invalid

These were confirmed invalid via `aws appsync evaluate-code`:
```
Error: Invalid function: defaultIfNull [code: INVALID_FUNCTION_INVOCATION]
```

**Fix:** Replace with JS equivalents:

| VTL function | JS replacement |
|---|---|
| `util.defaultIfNull(x, d)` | `(x ?? d)` |
| `util.defaultIfNullOrBlank(x, d)` | `(x ?? d)` |
| `util.isNull(x)` | `(x == null)` |
| `util.isNullOrBlank(x)` | `(x == null \|\| x === '')` |

Applies to ~30 occurrences across `listAllItems`, `queryByIndex*`, `resolveId*`, and nested resolver templates.

**Already applied locally** — verify with `grep "defaultIfNull\|isNullOrBlank" AppSync_Resolver_Functions.res` (should return no matches).

**Impact:** All existing VTL-based resolvers are already deployed and won't be affected until redeployed. When redeployed they'll get the JS versions, which are functionally equivalent.

---

## Step 3 — Validate

- Rebuild core: `cd reventless/reventless-core && npx rescript clean && npx rescript build`
- Run core tests
- Rebuild reventless-aws: `cd reventless/reventless-aws && npx rescript build`
- Run AWS adapter tests if any

---

## Step 4 — Publish

Publish new alpha versions of:
- `@reventlessdev/reventless-core`
- `@reventlessdev/rescript-pulumi-aws`

Then update downstream consumers to use published versions.

---

## Notes

- The `Plugin.make` signature change (removed `~api`, `~apiRole`, `~scheduler`) is not a fix but a compatibility note — these parameters are now set via hooks before plugin construction. Downstream consumers need to adapt their `make` functions accordingly.
- The Pulumi AWS provider 7.19.0 has a bug where its internal esbuild validator crashes with "SetFS() not initialized" when validating APPSYNC_JS resolver code. This masked the real error (invalid VTL functions) with a misleading message. Upgrading to 7.24.0 gives clearer errors but requires redeploying platform-aws first.
