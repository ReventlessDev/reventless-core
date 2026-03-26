---
title: Identity
date: 2026-03-26
draft: false
---

The `Identity` module provides a structured, provider-agnostic representation of the authenticated user for each request. It replaces the untyped `meta.user` string with a rich type that carries userId, username, groups, claims, and provider information.

## Type Definition

```rescript
type provider = Cognito | InMemory | Custom(string)

type t = {
  userId: string,
  username: string,
  groups: array<string>,
  claims?: dict<string>,
  provider: provider,
}
```

| Field | Description |
|-------|-------------|
| `userId` | Unique user identifier (e.g., Cognito `sub`, database ID). Persisted as `meta.user` on events. |
| `username` | Display name for logging and diagnostics. |
| `groups` | Authorization groups the user belongs to (e.g., `["admin", "editors"]`). |
| `claims` | Optional key-value pairs for custom claims (e.g., tenant ID, roles). |
| `provider` | Which identity provider authenticated this user. |

## Providers

| Provider | When Used |
|----------|-----------|
| `Cognito` | AWS deployments using Amazon Cognito for authentication. |
| `InMemory` | Local development and testing with the in-memory platform. |
| `Custom(string)` | Third-party identity providers (e.g., `Custom("auth0")`, `Custom("oauth2")`). |

## Anonymous Identity

When no identity is available (e.g., system-initiated actions, missing headers), the framework falls back to `Identity.anonymous`:

```rescript
let anonymous: t = {
  userId: "anonymous",
  username: "anonymous",
  groups: [],
  provider: InMemory,
}
```

## Helpers

### hasGroup

Check whether the identity belongs to a specific group:

```rescript
let hasGroup: (t, string) => bool

// Example
if identity->Identity.hasGroup("admin") {
  // allow operation
}
```

### getClaim

Retrieve a custom claim value:

```rescript
let getClaim: (t, string) => option<string>

// Example
switch identity->Identity.getClaim("tenantId") {
| Some(tenantId) => // use tenant context
| None => // no tenant claim
}
```

## Identity at the API Boundary

Identity is extracted at the API entry point and lives only in [RequestContext](request-context.md) for the duration of the request. It is **not** persisted with events.

### In-Memory Platform (GraphQL)

The in-memory GraphQL server reads the `X-Identity` header from incoming requests. The header value is a JSON-encoded `Identity.t`:

```json
{
  "userId": "user-123",
  "username": "alice",
  "groups": ["admin", "editors"],
  "claims": { "tenantId": "acme" },
  "provider": "Cognito"
}
```

If the header is absent or cannot be parsed, the resolver falls back to `Identity.anonymous`. This fail-silent behavior keeps the framework non-opinionated about authorization — strictness is the responsibility of application-level code.

### AWS (AppSync + Cognito)

On AWS, AppSync extracts identity from the Cognito JWT automatically. The VTL request mapping template reads:

- `$context.identity.username` &rarr; `meta.user`
- `$context.identity.sourceIp` &rarr; `meta.ip`

Cognito groups are available via AppSync directives for field-level authorization.

## What Is Persisted

Only `identity.userId` is persisted, as the existing `meta.user` string field on every event. The full `Identity.t` (groups, claims, provider) is **not** stored in events.

**Rationale:**

1. **Storage cost** &mdash; Groups, claims, and provider repeated on every event adds hundreds of bytes across millions of events.
2. **GDPR** &mdash; Events are immutable. Persisting PII in immutable events conflicts with the right to erasure.
3. **Staleness** &mdash; Groups and roles change over time. For point-in-time audit, a user management system can answer "what roles did user X have at time T?" from its own event stream.
4. **Schema stability** &mdash; Adding `Identity.t` to the serialized `meta` would change the event envelope format for every aggregate.

## Schema

`Identity.t` uses `@schema` (sury-ppx) for automatic JSON serialization. Use `Reventless.Identity.schema` for encoding and decoding:

```rescript
// Encode
let json = identity->S.reverseConvertToJsonOrThrow(Reventless.Identity.schema)

// Decode
let identity = json->S.parseJsonOrThrow(Reventless.Identity.schema)
```
