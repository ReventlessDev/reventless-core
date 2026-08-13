---
title: Identity
date: 2026-03-26
draft: false
---

The `Identity` module provides a structured, provider-agnostic representation of the authenticated user for each request — a rich type that carries userId, username, groups, claims, and provider information.

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
| `InMemory` | Local development and testing with the local platform. |
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

### Local Platform (GraphQL)

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

## Acting as One of Your Roles

A user whose account holds several groups can choose to act as just one of them. The narrowing happens in the **token's own group claim**, so every enforcement point in the system agrees with the choice without knowing that roles exist: owner-scoped reads, command authorization, and field-level directives all read the same groups they always read.

That placement is the whole design. On AWS, `@authorize(AllowGroups([...]))` compiles to `@aws_auth`, which AppSync evaluates against `cognito:groups` *before any application code runs* — so a request header naming the desired role could scope reads correctly and still leave every group-gated mutation callable. Narrowing the claim itself avoids a mode that is right about the data and wrong about the writes.

### The rule

**The requested role must be one the caller already holds.** Narrowing only, never widening — so a client that tampers with the request can only ever reduce its own privilege. A request for a group the user does not hold is **refused**, not ignored and quietly minted at full membership.

### Asking for it

| Platform | How | Result |
|----------|-----|--------|
| Local | `activeRole` on the login body, or `POST /__inmemory/switch-role` with a bearer token | A new token, minted immediately |
| AWS | The `Platform_SetActiveRole` mutation, then a token refresh | The next token Cognito mints carries the narrowed claim |

On AWS the choice is stored server-side and applied by a pre-token-generation trigger, because Cognito does not pass client metadata to that trigger on a refresh flow. The mutation records the preference against the authenticated caller's own subject — there is no argument naming a user, so it can only ever address the caller themselves.

Passing no role (or `null`) clears the choice and widens back to full membership. That is not an escalation: the set being widened to is the one the identity provider says the caller holds, re-read at that moment rather than taken from the token.

### Claims on a narrowed token

| Claim | Meaning |
|-------|---------|
| `activeRole` | The role the caller is acting as. Its presence *is* the answer to "am I narrowed right now?" |
| `availableRoles` | The caller's full membership, comma-joined, so a client can offer the switch back |
| `activeRoleStale` | AWS only: a stored role the caller no longer holds. The token carries full membership instead |

Both `activeRole` and `availableRoles` are absent from an unnarrowed token, so an ordinary login is unchanged by this feature.

:::danger Never authorize against `availableRoles`
It is by definition **wider** than what the caller is currently permitted — it exists so a client can render the switch back, and nothing else. Every enforcement point reads `groups`. This is the one part of an identity that deliberately describes privilege the caller does not currently have.
:::

### Safety, not a security boundary

:::warning This mechanism prevents accidents, not attacks
A token already issued stays valid until it expires. Choosing a role narrows the tokens minted *afterwards* and revokes nothing — a caller who kept an earlier token, or a request already in flight, still carries the wider claim until it lapses.

So this is a mechanism for stopping an operator from acting with elevated rights **by accident**, which is a real and common failure. It is **not** a mechanism for containing one who is trying to. Containing that needs short token lifetimes and a revocation path, which this does not provide.
:::

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
