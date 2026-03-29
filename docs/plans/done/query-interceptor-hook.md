# Query Interceptor Hook

## Status

**Done.** Implemented 2026-03-29.

---

## Problem

There is no interception point in the query path. Commands have `CommandGenerator_Callback.commandInterceptorHook` — a module-level ref that `makeGenerateCommand` checks before every publish. Queries have no equivalent. Any library or framework layer that needs to run logic before a query executes (auth checks, rate limiting, auditing) has no supported way to do it.

---

## Design

### Transport-agnostic hook in `QueryDb_Callback`

The hook lives in `reventless-core` and is transport-agnostic. Each transport adapter (GraphQL, OpenAPI, etc.) is responsible for:

1. Extracting `identity` and `args` from its own request context
2. Calling `QueryDb_Callback.queryInterceptorHook` before executing the query
3. Mapping `Deny` to the appropriate transport-level error or empty response

This mirrors the command interceptor pattern: `CommandGenerator_Callback` holds the hook; `CommandGeneratorResolvers_GraphQL` (and future transport adapters) call it.

**AWS AppSync is the exception.** AppSync query resolvers are pure VTL templates that map directly to DynamoDB without invoking a Lambda. There is no runtime code to call the hook from — explicitly deferred, same situation as AppSync was for command interception. Auth for AppSync queries must be implemented via AppSync authorization (Cognito User Pools, Lambda authorizers, or field-level auth directives).

---

## Step 1: `QueryDb_Callback.res` — new file

**File:** `reventless-core/src/components/QueryDb/QueryDb_Callback.res`

```rescript
type interceptResult = Allow | Deny(string)

type queryInterceptor = (
  ~identity: Reventless.Identity.t,
  ~readModelName: string,
  ~args: JSON.t,
) => promise<interceptResult>

/** Module-level interceptor hook. None = passthrough (default). */
let queryInterceptorHook: ref<option<queryInterceptor>> = ref(None)
```

`None` = passthrough (default). Set once at startup by the consumer. Mirrors `CommandGenerator_Callback.commandInterceptorHook`.

The hook signature is transport-agnostic: `identity` is already extracted, `args` is plain JSON. Transport adapters are responsible for bridging their native context to these types.

---

## Step 2: GraphQL adapter — `QueryDbResolvers_GraphQL.res`

**File:** `reventless-in-memory/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res`

Three changes:

### 2a. Extract identity from GraphQL context

Add `extractIdentity` at the top of the `Make` functor (same pattern as `CommandGeneratorResolvers_GraphQL`):

```rescript
@send external getHeader: ('headers, string) => Nullable.t<string> = "get"

let extractIdentity = (ctx: JSON.t): Reventless.Identity.t => {
  try {
    let request = (ctx->Obj.magic)["request"]
    let headers = request["headers"]
    switch headers->getHeader("x-identity")->Nullable.toOption {
    | Some(json) => json->JSON.parseOrThrow->S.parseOrThrow(Reventless.Identity.schema)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }
}
```

### 2b. Add a shared `runInterceptor` helper

```rescript
let runInterceptor = async (~ctx, ~args): QueryDb_Callback.interceptResult => {
  switch QueryDb_Callback.queryInterceptorHook.contents {
  | None => Allow
  | Some(interceptor) =>
    await interceptor(
      ~identity=extractIdentity(ctx),
      ~readModelName=name,
      ~args,
    )
  }
}
```

`name` is already in scope from the outer `make` function.

### 2c. Call `runInterceptor` in each resolver

For every resolver that currently ignores `_ctx`, rename to `ctx` and check the hook before executing:

**`byIdResolver`:**
```rescript
let byIdResolver: GraphQL_Server.resolverFn = async (_root, args, ctx) => {
  switch await runInterceptor(~ctx, ~args) {
  | Deny(_) => JSON.Encode.null
  | Allow =>
    // ... existing implementation unchanged ...
  }
}
```

**`listResolver`:**
```rescript
let listResolver: GraphQL_Server.resolverFn = async (_root, args, ctx) => {
  switch await runInterceptor(~ctx, ~args) {
  | Deny(_) => Obj.magic({"nextToken": Nullable.null, "scannedCount": 0, "items": []})
  | Allow =>
    // ... existing implementation unchanged ...
  }
}
```

**`byIdListResolver`** (inner resolver lambda) and each **`indexResolver`** — same pattern, returning `[]->JSON.Encode.array` on `Deny`.

---

## Future transports (OpenAPI, REST, etc.)

Any future query transport adapter follows the same three-step pattern:

1. **Extract identity** from the transport's native request object (headers, JWT, session, etc.)
2. **Call `runInterceptor`** (or inline the hook call) using the extracted identity and query args as plain `JSON.t`
3. **Map `Deny`** to the appropriate transport-level response (HTTP 403, empty body, etc.)

No changes to `QueryDb_Callback.res` are needed for new transports — the hook is set once at startup and called by every transport adapter.

---

## Summary

| File | Repo | Change |
|---|---|---|
| `QueryDb_Callback.res` | reventless-core | New — transport-agnostic hook type + ref |
| `QueryDbResolvers_GraphQL.res` | reventless-in-memory | Edit — add `extractIdentity`, `runInterceptor`, call in 4 resolver types |

Two files for the initial GraphQL implementation. Future transports add their own adapter files without touching `QueryDb_Callback`.
