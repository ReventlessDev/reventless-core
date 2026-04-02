# Plan: AppSync VTL → JavaScript Resolver Migration

**Analysis:** `docs/analysis/appsync-vtl-to-javascript-resolver-migration.md`

**Scope:** Replace all 29 VTL templates in `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Templates.res` with ReScript functions compiling to APPSYNC_JS runtime. Scoped entirely to AppSync — no other services use VTL.

**Approach:** Four phases: Pulumi bindings → ReScript bindings for `@aws-appsync/utils` → template library migration → adapter wiring. Each phase independently deployable. VTL fields remain optional throughout for backward compatibility.

---

## Phase 1 — Pulumi Bindings Update

### 1.1 Update `AppSync_Resolver.res`
- [ ] Add `runtime` type: `{ name: string, runtimeVersion: string }`
- [ ] Add `runtime` and `code` fields to `args` (optional, for backward compat)
- [ ] Keep `requestMappingTemplate` / `responseMappingTemplate` as optional
- [ ] Verify Pulumi provider supports `runtime`/`code` fields (check AWS provider schema)

### 1.2 Update `AppSync_Function.res`
- [ ] Same `runtime` and `code` additions as `AppSync_Resolver.res`
- [ ] Keep existing VTL fields optional

### 1.3 Add `deleteBeforeReplace` support
- [ ] Document that resolver resources switching from VTL to JS require `deleteBeforeReplace: true` in Pulumi options
- [ ] Add note in `AppSync_Resolver.res` inline comments

---

## Phase 2 — ReScript Bindings for `@aws-appsync/utils`

### 2.1 Create `rescript-appsync-utils` package (or add to `rescript-pulumi-aws`)
- [ ] Decide: new `rescript/rescript-appsync-utils` package vs module inside `rescript-pulumi-aws/src/AppSync/`
- [ ] Bind `util.dynamodb.toMapValues`, `util.dynamodb.toString`, `util.dynamodb.toStringSet`, etc.
- [ ] Bind `util.unauthorized()`, `util.error(message, errorType)`
- [ ] Bind `runtime.earlyReturn(value)`
- [ ] Bind `ctx` object shape: `ctx.args`, `ctx.identity`, `ctx.result`, `ctx.error`, `ctx.info.fieldName`
- [ ] Write minimal types for DynamoDB request/response shapes

### 2.2 Add esbuild bundling step
- [ ] Add `esbuild` as dev dependency in the relevant package
- [ ] Write a bundler script that takes a `.res.mjs` module and emits a single-file string
- [ ] Integrate into `npm run build` for the resolver package
- [ ] Verify the bundle passes AppSync's single-file constraint (no external imports at runtime)

---

## Phase 3 — Template Library Migration

### 3.1 DynamoDB read templates (9 templates → ReScript functions)
- [ ] `getItemById` → `request`/`response` pair
- [ ] `queryById`, `queryByIdSort`
- [ ] `queryByIndex`, `queryByIndexDeletable`, `queryByIndexSort`
- [ ] `queryByIndexSortFiltered` (71-line VTL → ~20-line ReScript, highest priority for correctness)
- [ ] `listAllItems`

### 3.2 DynamoDB resolve/ID templates (7 templates)
- [ ] `resolveId`, `resolveIdSort`, `resolveIdSortArgument`
- [ ] `resolveIdByIndex`, `resolveIdByIndexSort`, `resolveIdByIndexSortArgument`
- [ ] `resolveIds` (BatchGetItem)

### 3.3 DynamoDB write templates (3 templates)
- [ ] `putItem`
- [ ] `addItemToList`
- [ ] `deleteItem`

### 3.4 Lambda invocation templates (3 templates)
- [ ] `invokeCommandGenerator`
- [ ] `invokeDcbMutation`
- [ ] `invokeInboundTranslation`

### 3.5 Authorization templates (2 templates)
- [ ] `authorizeIndexedAccessRequest`
- [ ] `authorizeIndexedAccessResponse`

### 3.6 Response templates (6 templates)
- [ ] `result`, `firstResult`, `resultList`
- [ ] `resolveIdResult`, `resolveIdResults`, `resolveIdsResult`
- [ ] `null`

---

## Phase 4 — Adapter Wiring

### 4.1 Update `QueryDbResolvers_AppSync.res`
- [ ] Replace template string calls with JS resolver builder calls
- [ ] Pass bundled code string to `AppSync_Resolver` args as `code`
- [ ] Set `runtime` field to `{ name: "APPSYNC_JS", runtimeVersion: "1.0.0" }`
- [ ] Remove `requestMappingTemplate` / `responseMappingTemplate` fields

### 4.2 Update `CommandGeneratorResolvers_AppSync.res`
- [ ] Same pattern as QueryDb adapters

### 4.3 Update `InboundTranslationResolvers_AppSync.res`
- [ ] Same pattern

### 4.4 Remove VTL template library
- [ ] Delete or archive `AppSync_Resolver_Templates.res` once all adapters are migrated
- [ ] Remove VTL optional fields from Pulumi bindings

---

## Phase 5 — Testing

### 5.1 Unit tests for request/response functions
- [ ] For each migrated template: test `request(ctx)` returns correct DynamoDB/Lambda request shape
- [ ] For each migrated template: test `response(ctx)` handles `ctx.error` and happy path
- [ ] Test `queryByIndexSortFiltered` with all filter combinations

### 5.2 E2E verification
- [ ] Deploy one resolver (e.g., `getItemById`) via JS runtime to a dev AppSync API
- [ ] Verify CloudWatch logs show JS stack traces (not VTL rendering errors)
- [ ] Smoke test each adapter category (query, mutation, inbound translation)

### 5.3 Verify AWS region availability
- [ ] Confirm APPSYNC_JS runtime is available in all target deployment regions

---

## Migration Order (Recommended)

Start with the highest-value targets to validate the pipeline before full migration:

1. `queryByIndexSortFiltered` — most complex VTL, most likely to have hidden bugs
2. `authorizeIndexedAccessRequest` / `authorizeIndexedAccessResponse` — authorization correctness critical
3. Lambda invocation templates — simple, validates the bundling pipeline end-to-end
4. Remaining DynamoDB templates in bulk

Each resolver can be migrated independently (different Pulumi resources) — no big-bang cutover needed.
