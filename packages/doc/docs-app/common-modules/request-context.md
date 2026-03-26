---
title: RequestContext
date: 2026-03-26
draft: false
---

`RequestContext` is an Effect service that carries per-request data through the pipeline without explicit argument threading. It is populated at the API entry point and discarded after the response is sent.

## Type Definition

```rescript
type t = {
  correlationId: string,
  identity: Identity.t,
  claims: dict<string>,
}
```

| Field | Description | Persisted? |
|-------|-------------|------------|
| `correlationId` | Links related messages across the system. | Yes &mdash; as `meta.correlationId` |
| `identity` | The authenticated user for this request (see [Identity](identity.md)). | Only `identity.userId` &mdash; as `meta.user` |
| `claims` | Custom key-value pairs for per-request context (e.g., tenant ID, feature flags). | No |

## Persisted vs. In-Memory

```
+---------------------------------------------------------------------+
|  RequestContext (in-memory, per-request)                              |
|                                                                      |
|  correlationId: string  -->  meta.correlationId (persisted)          |
|  identity: Identity.t   -->  meta.user = identity.userId (persisted) |
|  claims: dict<string>   -->  NOT persisted                           |
|                                                                      |
|  Available to: resolvers, application code                           |
|  Lifetime: single request, discarded after response                  |
+---------------------------------------------------------------------+
```

The `claims` dict is purely transient. Use it for information that should influence request processing but should not be stored in the event stream (e.g., tenant context, feature flags, tracing metadata).

## Usage

### Providing RequestContext

At the Lambda handler or resolver entry point:

```rescript
let ctx: RequestContext.t = {
  correlationId: event.meta.correlationId,
  identity,
  claims: Dict.make(),
}

myEffect
->Effect.provideService(RequestContext.tag, ctx)
->Effect.runPromise
```

### Reading RequestContext

Inside any Effect in the pipeline:

```rescript
Effect.serviceWith(RequestContext.tag, ctx => {
  let userId = ctx.identity.userId
  let tenantId = ctx->RequestContext.getClaim("tenantId")
  // ...
})
```

### In Tests

The `test()` constructor provides sensible defaults:

```rescript
// All defaults: anonymous identity, empty claims, "test-correlation-id"
let ctx = RequestContext.test()

// Custom identity
let ctx = RequestContext.test(
  ~identity={
    userId: "user-1",
    username: "alice",
    groups: ["admin"],
    provider: Cognito,
  },
)

// Custom claims
let ctx = RequestContext.test(
  ~claims=Dict.fromArray([("tenantId", "acme")]),
)
```

## Helpers

### getClaim

Retrieve a claim value from the context:

```rescript
let getClaim: (t, string) => option<string>

switch ctx->RequestContext.getClaim("tenantId") {
| Some(tenantId) => // use tenant
| None => // no tenant claim
}
```

### withClaim

Return a new context with an added claim (immutable):

```rescript
let withClaim: (t, string, string) => t

let enriched = ctx->RequestContext.withClaim("tenantId", "acme")
// original ctx is unchanged
```

## How Identity Flows Through the System

1. **API boundary** (GraphQL resolver, Lambda handler): Extract identity from the request (header, JWT, Cognito context).
2. **RequestContext**: Populate `identity` field. Set `payload.meta.user = identity.userId`.
3. **CommandGenerator**: Transforms `payload.meta` into `Message.meta`. The `user` field is propagated unchanged.
4. **Event persistence**: `meta.user` (= `identity.userId`) and `meta.correlationId` are stored with every event.
5. **Response**: RequestContext is discarded. Full identity (groups, claims, provider) is not retained.
