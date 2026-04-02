# AppSync VTL → JavaScript (ReScript) Resolver Migration Analysis

## Executive Summary

AWS AppSync supports two resolver runtimes: **VTL** (Velocity Template Language, the original) and **JavaScript** (APPSYNC_JS runtime, launched in 2022). Migrating from VTL to JavaScript — and specifically to ReScript compiling to that JavaScript — is technically feasible and offers meaningful advantages, but carries non-trivial migration cost.

---

## Current State

### VTL in Reventless

All VTL is embedded as ReScript string literals — there are no `.vtl` files. The templates are centralized in one library file and referenced from a small set of adapter files:

| File | Role |
|------|------|
| `rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Templates.res` | All 29 VTL template strings (~650 lines) |
| `reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res` | Read model query resolvers |
| `reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res` | Mutation resolvers (Aggregate + DCB) |
| `reventless-aws/src/adapter/CommandGenerator/InboundTranslationResolvers_AppSync.res` | Inbound translation slice resolvers |
| `rescript-pulumi-aws/src/AppSync/AppSync_Resolver.res` | Pulumi resolver resource bindings |
| `rescript-pulumi-aws/src/AppSync/AppSync_Function.res` | Pulumi pipeline function bindings |

### Template Inventory

**DynamoDB request templates (15):**
- `getItemById`, `queryById`, `queryByIdSort`
- `queryByIndex`, `queryByIndexDeletable`, `queryByIndexSort`, `queryByIndexSortFiltered`
- `authorizeIndexedAccessRequest`
- `listAllItems`
- `resolveId`, `resolveIdSort`, `resolveIdSortArgument`
- `resolveIdByIndex`, `resolveIdByIndexSort`, `resolveIdByIndexSortArgument`
- `resolveIds` (BatchGetItem)
- `putItem`, `addItemToList`, `deleteItem`

**Lambda invocation templates (3):**
- `invokeCommandGenerator`, `invokeDcbMutation`, `invokeInboundTranslation`

**Authorization templates (2):**
- `authorizeIndexedAccessRequest`, `authorizeIndexedAccessResponse`

**Response templates (6):**
- `result`, `firstResult`, `resultList`, `resolveIdResult`, `resolveIdResults`, `resolveIdsResult`, `null`

### Resolver Patterns

- **Unit resolvers** — direct DataSource → response (DynamoDB queries and Lambda invocations)
- **Pipeline resolvers** — sequence of AppSync Functions (interceptor Lambda → DynamoDB, or auth check → DynamoDB)

---

## JavaScript Runtime (APPSYNC_JS) Overview

AppSync's JS runtime runs on a V8-based sandbox (not Node.js). Constraints:
- No `require()` / `import` at runtime
- No `Date`, `Math.random`, timers, network I/O
- No arbitrary npm packages — only the built-in `@aws-appsync/utils` module
- Code must be **bundled into a single file** per resolver/function
- Supports ES2022 syntax (async/await, optional chaining, etc.)

AWS provides utility helpers in `@aws-appsync/utils` that mirror the VTL `$util.*` helpers:
- `util.dynamodb.toMapValues()`, `util.dynamodb.toString()`, etc.
- `util.unauthorized()`, `util.error()`
- `runtime.earlyReturn()`

---

## Migration: VTL Template → JS Equivalent

Every VTL construct has a clean JavaScript equivalent. Examples:

### DynamoDB Query (VTL)
```vtl
{
  "version": "2017-02-28",
  "operation": "Query",
  "query": {
    "expression": "#id = :id",
    "expressionNames": {"#id": "$idField"},
    "expressionValues": {":id": $util.dynamodb.toString($ctx.args.id)}
  }
}
```

### DynamoDB Query (APPSYNC_JS)
```javascript
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: '#id = :id',
      expressionNames: { '#id': 'id' },
      expressionValues: { ':id': util.dynamodb.toString(ctx.args.id) }
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message);
  return ctx.result.items[0] ?? null;
}
```

### Lambda Invocation (VTL)
```vtl
{
  "version": "2018-05-29",
  "operation": "Invoke",
  "payload": {
    "commandName": "$ctx.info.fieldName",
    "arguments": $util.toJson($ctx.args),
    "identity": $util.toJson($ctx.identity)
  }
}
```

### Lambda Invocation (APPSYNC_JS)
```javascript
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  return {
    operation: 'Invoke',
    payload: {
      commandName: ctx.info.fieldName,
      arguments: ctx.args,
      identity: ctx.identity
    }
  };
}
export function response(ctx) {
  if (ctx.error) util.error(ctx.error.message);
  return ctx.result;
}
```

---

## Reventless-Specific Approach: ReScript → APPSYNC_JS

Instead of writing resolver logic in JavaScript directly, Reventless would compile ReScript to JavaScript and bundle it. This is a natural fit because all resolver logic is already expressed in ReScript — the VTL strings would be replaced by real ReScript functions.

### Build pipeline change

Current:
```
ReScript (AppSync_Resolver_Templates.res)
  → ReScript compiler
  → CommonJS .res.js (containing VTL strings)
  → Pulumi reads strings → AppSync API
```

Proposed:
```
ReScript (AppSync_Resolver_Templates.res / new files)
  → ReScript compiler
  → ESM .res.mjs (JS resolver module)
  → esbuild bundles to single file
  → Pulumi reads bundled string → AppSync API
```

### Pulumi resource change

`AppSync_Resolver.res` args would gain a `runtime` field and drop separate `requestTemplate` / `responseTemplate` in favour of a single `code` field:

```rescript
type args = {
  apiId: Pulumi.Input.t<string>,
  dataSource?: Pulumi.Input.t<string>,
  field: Pulumi.Input.t<string>,
  @as("type") type_: Pulumi.Input.t<string>,
  runtime: Pulumi.Input.t<runtime>,   // { name: "APPSYNC_JS", runtimeVersion: "1.0.0" }
  code: Pulumi.Input.t<string>,       // bundled JS as string
  // requestTemplate / responseTemplate removed
}
```

The same change applies to `AppSync_Function.res` for pipeline functions.

---

## Effort Estimate

### Phase 1 — Pulumi bindings update (~1–2 days)
- Update `AppSync_Resolver.res` and `AppSync_Function.res` to support the JS runtime fields
- Keep the VTL fields as optional for backward compatibility during migration

### Phase 2 — Template library migration (~3–5 days)
- Replace `AppSync_Resolver_Templates.res` with a new `AppSync_Resolver_Functions.res` (or per-category files)
- Each of the 29 templates becomes a pair of `request`/`response` ReScript functions
- Add an esbuild bundling step that reads each `.res.mjs` and emits a single-file string

### Phase 3 — Adapter wiring (~2–3 days)
- Update `QueryDbResolvers_AppSync.res`, `CommandGeneratorResolvers_AppSync.res`, and `InboundTranslationResolvers_AppSync.res` to call the new JS-based builders instead of the template string builders

### Phase 4 — Testing (~2–3 days)
- Unit tests for each request/response function
- E2E tests against a live or mocked AppSync endpoint

**Total rough estimate: ~1.5–2.5 weeks** for one focused engineer.

---

## Advantages

### Correctness and Type Safety
- **No more string template bugs.** VTL errors (mismatched braces, incorrect `$util` calls, typos in field names) are invisible to the ReScript type checker. JavaScript resolver code is real code the compiler checks.
- **Shared type definitions.** Resolver functions can import and reuse the same ReScript types defined in the spec packages, eliminating the dual-representation problem (ReScript type + VTL string that must stay in sync).
- **IDEs understand the code.** ReScript LSP provides hover types and go-to-definition inside resolver functions; VTL is opaque string data.

### Testability
- **Unit-testable in Jest.** Request and response functions are pure functions — given a `ctx` object, they return a DynamoDB request. VTL templates can only be tested by deploying to AppSync.
- **No resolver-level infrastructure round-trips needed** to verify logic during development.

### Maintainability
- **Refactoring is safe.** Renaming a DynamoDB attribute today requires a text search through VTL strings. With ReScript, a rename triggers a compiler error everywhere the field is referenced.
- **Conditional complexity is readable.** The `queryByIndexSortFiltered` template (71 lines of nested `#foreach`/`#if` VTL) would be ~20 lines of idiomatic ReScript.
- **Debugging is easier.** AppSync CloudWatch logs for JS resolvers show JavaScript stack traces, not VTL rendering errors.

### Developer Experience
- **Onboarding is easier.** New developers do not need to learn VTL syntax in addition to ReScript, Pulumi, and AppSync concepts.
- **One language for everything.** The full stack from domain logic to resolver mapping is ReScript.

### Features
- **Async pipeline functions.** The JS runtime supports `async/await` in pipeline functions, enabling patterns that require async coordination without a Lambda round-trip.
- **Better error handling.** JavaScript exceptions produce structured errors; VTL error handling requires carefully crafted conditional blocks.

---

## Consequences and Risks

### Bundle step required
Each resolver needs its code bundled into a single self-contained file before being passed to Pulumi as a string. This requires adding an esbuild (or rollup) step to the deploy pipeline. The bundle must not include Node.js-specific APIs or arbitrary npm packages.

### Runtime constraints
The APPSYNC_JS sandbox does not have `Date`, timers, or I/O. Current VTL templates do not use these — but any future resolver code must respect these constraints. Developers unfamiliar with the sandbox limitations could accidentally write code that compiles but fails at runtime.

### No VTL-style DynamoDB type helpers in ReScript (yet)
The `@aws-appsync/utils` package provides `util.dynamodb.*` helpers. ReScript bindings for this module would need to be created in `rescript-pulumi-aws` (or a new `rescript-appsync-utils` package). These bindings are straightforward but are a prerequisite.

### Existing deployments need resolver replacement
Migrating from `requestMappingTemplate`/`responseTemplate` to `code`/`runtime` on a live AppSync API requires replacing (not updating) resolver resources in Pulumi. This means `deleteBeforeReplace: true` on resolver resources during the migration deploy — brief downtime per resolver. This is manageable with a phased rollout per plugin.

### AWS region/feature availability
APPSYNC_JS is available in all major AWS regions but should be verified against the target deployment regions.

---

## Other Services Using VTL in Reventless

### Scope of VTL in the codebase

A search across the full repository finds VTL usage **exclusively in AppSync resolver templates**. There is no VTL usage in:

- **API Gateway** — Reventless uses Lambda proxy integrations (no mapping templates)
- **DynamoDB Streams** — processed via Lambda, not VTL
- **SQS/SNS** — no VTL mapping
- **EventBridge** — no VTL mapping (input transformers use a different JSON-based syntax)
- **S3** — no VTL
- **Cognito** — Lambda triggers, not VTL

#### VTL in other AWS services (not currently used by Reventless)

For completeness, AWS also supports VTL-like templating in:
- **API Gateway REST APIs** — request/response mapping templates (JSON/VTL). Reventless uses Lambda proxy, so these are not in use.
- **CloudFormation** — uses `Fn::Sub` and `Fn::Transform` (not VTL) for template substitution.

**Conclusion:** This migration is scoped entirely to AppSync. No other services need to change.

---

## Recommendation

The migration is worth doing, but not urgently. The key inflection point is when the resolver template library needs to grow significantly (new query patterns, authorization schemes, or DCB variants) — at that point the testability and type-safety benefits of JS resolvers outweigh the migration cost.

A pragmatic path:
1. **Short-term:** Add ReScript bindings for `@aws-appsync/utils` and the JS runtime Pulumi fields (low risk, enables new resolvers to be written in JS).
2. **Medium-term:** Migrate the most complex templates first (`queryByIndexSortFiltered`, authorization pipeline) where correctness bugs are most likely.
3. **Long-term:** Complete migration of all 29 templates, remove the VTL template library.

The bundling step is the only genuine infrastructure addition. Everything else replaces existing string manipulation with type-safe ReScript code.
