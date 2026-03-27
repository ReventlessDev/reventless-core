# Identity Type and RequestContext Expansion

This plan adds a structured identity type and expands `RequestContext` to carry identity and custom claims through the request lifecycle. These are foundational improvements for any multi-user application.

---

## Current State

| Area | Current State | Gap |
|------|--------------|-----|
| **Identity** | `meta.user` is a plain string; GraphQL resolver hardcodes `user: "local"`; AWS uses Cognito groups via AppSync directives | No framework-level identity type; authorization is Cognito-specific, not pluggable |
| **RequestContext** | Carries `correlationId` only; comment says "extend with tenantId, userId, traceId" | No identity; no claims; no tenant context |

---

## Step 1: Structured Identity Type

**Goal:** Replace the unstructured `meta.user` string with a typed identity that carries userId, groups, claims, and provider information.

### Identity Is Not Persisted in Events

The full `Identity.t` lives only in `RequestContext` (in-memory, per-request). It is **not** added to `Message.meta` and is **not** persisted with events. Only the existing `meta.user` string (= userId) is stored.

**Rationale:**

1. **Storage cost.** Groups, claims, and provider repeated on every event adds hundreds of bytes per event across millions of events.
2. **GDPR conflict.** Events are immutable. Persisting PII in immutable events contradicts the right to erasure.
3. **Stale-by-design.** Groups and roles change over time. For point-in-time audit, an event-sourced user management system can answer "what roles did user X have at time T?" from its own event stream.
4. **Schema stability.** Adding `Identity.t` to serialized `meta` changes the event envelope format for every aggregate.

The `meta.user` string is the correlation key.

### Files to Change

**New file — `reventless/reventless-spec/src/types/Identity.res`:**

```rescript
@schema
type provider = Cognito | InMemory | Custom(string)

@schema
type t = {
  userId: string,
  username: string,
  groups: array<string>,
  claims?: dict<string>,
  provider: provider,
}

let anonymous: t = {
  userId: "anonymous",
  username: "anonymous",
  groups: [],
  provider: InMemory,
}

let hasGroup: (t, string) => bool
let getClaim: (t, string) => option<string>
```

**No change to `Message.meta`.** The `meta` type stays as-is.

**Modify — `reventless/reventless-core/src/RequestContext.res`:**

```rescript
type t = {
  correlationId: string,
  identity: Identity.t,
}
```

**Modify — GraphQL resolvers (in-memory):**

`reventless/reventless-in-memory/src/adapter/CommandGenerator/CommandGeneratorResolvers_GraphQL.res`:
- Read `X-Identity` header (JSON-encoded `Identity.t`) from the GraphQL request context
- Fall back to `Identity.anonymous` if absent
- Populate `RequestContext.identity`; set `meta.user` to `identity.userId`

**Modify — MCP server (in-memory):**

Same pattern.

**Modify — AWS resolvers:**

`reventless/reventless-aws/src/adapter/CommandGenerator/CommandGeneratorResolvers_AppSync.res`:
- Extract identity from Cognito JWT claims
- Map `cognito:groups` → `identity.groups`, `sub` → `identity.userId`
- Set `provider: Cognito`; populate `RequestContext.identity`

### Tests

- `reventless/reventless-core/tests/IdentityTest.res` — `hasGroup`, `getClaim`, schema roundtrip
- Update `CommandGeneratorCallbackTest.res` to supply identity in RequestContext
- `reventless/reventless-in-memory/tests/components/commandgenerator/CommandGeneratorIdentityTest.res` — Header extraction
- Verify persisted events do **not** contain `identity` in `meta`

---

## Step 2: RequestContext Expansion

**Goal:** Add extensible claims dict to `RequestContext` for custom per-request context.

### What Is Persisted vs. What Is In-Memory

```
┌─────────────────────────────────────────────────────────────────────┐
│  RequestContext (in-memory, per-request)                            │
│                                                                     │
│  correlationId: string  ──→  meta.correlationId (persisted)         │
│  identity: Identity.t   ──→  meta.user = identity.userId (persisted)│
│  claims: dict<string>   ──→  NOT persisted                          │
│                                                                     │
│  Available to: resolvers, application code                          │
│  Lifetime: single request, discarded after response                 │
└─────────────────────────────────────────────────────────────────────┘
```

### Files to Change

**Modify — `reventless/reventless-core/src/RequestContext.res`:**

```rescript
type t = {
  correlationId: string,
  identity: Identity.t,
  claims: dict<string>,
}

let tag: Context.tag<t> = Context.genericTag("reventless/RequestContext")

let test = (~correlationId="test-correlation-id", ~identity=Identity.anonymous, ~claims=Dict.make()): t => {
  correlationId,
  identity,
  claims,
}

let getClaim: (t, string) => option<string>
let withClaim: (t, string, string) => t
```

**Modify — GraphQL/MCP resolvers:**

Populate `claims` from request headers at the API boundary.

### Tests

- Update existing `RequestContext` tests
- **Negative test:** Verify persisted events do not contain claims — only `meta.user` and `meta.correlationId`

---

## Step 3: Documentation

### New Documentation Pages

- `packages/doc/docs/reventless-components/identity.md` — Identity type, providers, claims, header format
- `packages/doc/docs/reventless-components/request-context.md` — RequestContext expansion, what is persisted vs. transient

### Updated Pages

- `packages/doc/docs/reventless-components/aggregate.md` — Mention identity available via RequestContext

---

## Implementation Order

```
Step 1: Identity Type              ✅ DONE
  │     (no dependencies)
  │
Step 2: RequestContext Expansion    ✅ DONE
  │     (depends on Step 1)
  │
Step 3: Documentation              ✅ DONE
        (depends on Steps 1-2)
```

Steps 1 and 2 can be combined into a single `feat!:` release since both modify `RequestContext.t`.

---

## Breaking Changes Summary

| Step | Breaking? | Impact |
|------|-----------|--------|
| 1. Identity type | Minor | New `Identity.res` module; new required field on `RequestContext.t`; no change to `Message.meta` or persisted event format |
| 2. RequestContext | Minor | New `claims` field on `RequestContext.t`; test helpers updated |
| 3. Documentation | No | New docs only |

Bundle Steps 1-2 into a single `feat!:` release. Pre-1.0 alpha, acceptable.

---

## Open Questions

1. **Sync vs async identity extraction:** Should the `X-Identity` header parsing fail silently (fall back to anonymous) or reject the request? Recommendation: fail silently with a warning log — strictness should be the responsibility of application-level authorization, not the framework.

2. **AWS query identity:** On AWS, queries go through AppSync → DynamoDB directly (not through a Lambda resolver for standard queries). Identity from Cognito is available via AppSync directives but not via `RequestContext`. Should the docs clarify this limitation?
