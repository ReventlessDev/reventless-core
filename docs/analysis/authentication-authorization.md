# Authentication & Authorization for GraphQL and MCP Servers

## 1. Current State

### What Exists Today

**Message metadata** carries a `user` field through the entire command/event pipeline:

```rescript
// reventless-spec/src/types/Message.res
type meta = {
  service: string,
  time: string,
  ip: string,
  user: string,        // ← caller identity
  msgId: string,
  correlationId: string,
}
```

**CommandGenerator** has its own lighter `meta` type used at the API boundary:

```rescript
// CommandGenerator.res
type meta = { ip: array<string>, user: string, info: string }
```

**Authorization on read models** is defined as a Cognito-group-to-table mapping:

```rescript
// reventless-spec/src/components/ReadModel.res
type authorization = { tableName: string, group: string }
```

**AWS AppSync** injects `@aws_auth(cognito_groups: ["Group"])` directives into the stitched SDL. Authentication type is hardcoded to `AMAZON_COGNITO_USER_POOLS`.

**In-memory GraphQL** (graphql-yoga) has no authentication — the `user` field in `CommandGenerator.meta` is hardcoded to `"local"`.

**MCP server** has no authentication on either platform.

### Gaps

| Area | Gap |
|------|-----|
| Authentication | Tightly coupled to Cognito; no abstraction for other providers |
| Authorization | Only applies to queries via `@aws_auth`; mutations have no authorization model |
| In-memory | No auth at all — acceptable for dev, but blocks integration testing of auth rules |
| MCP | No auth on either platform |
| User context | `CommandGenerator.meta.user` is a plain string set at the API boundary; no structured identity |
| Behavior access | `Message.context` carries `meta.user` into command handlers, but behaviors can't express authorization requirements declaratively |

---

## 2. Design Goals

1. **Provider-agnostic** — auth abstraction works across In-Memory, AWS (Cognito), and future providers (Auth0, Azure AD, etc.)
2. **Covers both servers** — same model for GraphQL and MCP
3. **Declarative authorization** — plugin authors express "who can do what" in their specs, not in handler code
4. **Structured identity** — replace the `user: string` with a typed identity carrying groups/roles/claims
5. **Client simplicity** — clients should authenticate once and use the same token for both GraphQL and MCP
6. **Testable** — in-memory provider allows deterministic testing of authorization rules without external IdP

---

## 3. Authentication Abstraction

### 3.1 Core Identity Type

Introduce a provider-agnostic identity representation in `reventless-spec`:

```rescript
// reventless-spec/src/types/Identity.res

@schema
type authProvider =
  | Cognito
  | Auth0
  | AzureAD
  | InMemory
  | ApiKey
  | Custom(string)

@schema
type identity = {
  userId: string,                 // unique user identifier (e.g. Cognito sub, Auth0 user_id)
  username: string,               // human-readable name
  groups: array<string>,          // authorization groups
  claims?: dict<string>,          // IdP-specific attributes (email, tenantId, locale, etc.)
  provider: authProvider,         // which IdP issued this identity
  issuer?: string,                // OIDC issuer URL when available (from JWT `iss` claim)
}

type authResult =
  | Authenticated(identity)
  | Anonymous
  | AuthError(string)
```

This replaces the current `user: string` in message metadata with structured data. The `groups` field directly maps to the existing `authorization.group` concept but generalizes it beyond Cognito.

**The `claims` field** is an optional escape hatch for IdP-specific attributes that don't map to the structured fields. Most authorization decisions use `groups` — `claims` is only needed when platform-specific attributes matter:

| Provider | Claim key | Example value | Use case |
|----------|-----------|---------------|----------|
| Cognito | `email` | `"alice@example.com"` | Display, notifications |
| Cognito | `email_verified` | `"true"` | Gate actions on verified accounts |
| Cognito | `custom:tenantId` | `"tenant-abc"` | Multi-tenant row filtering |
| Auth0 | `org_id` | `"org_123"` | Organization-scoped access |
| Auth0 | `permissions` | `"read:items,write:items"` | Fine-grained scopes beyond groups |
| Any OIDC | `given_name` | `"Alice"` | Personalization |
| Any OIDC | `locale` | `"en-US"` | i18n |
| API Key | `serviceName` | `"inventory-sync"` | Audit trail for service-to-service calls |

### 3.2 Authentication Provider Adapter

Define a new adapter interface that authentication providers implement:

```rescript
// reventless-core/src/adapter/Auth/Auth_Adapter.res

module type Provider = {
  /** Extract identity from an incoming request.
      For GraphQL: reads Authorization header or context.
      For MCP: reads Authorization header from Streamable HTTP request. */
  let authenticate: requestContext => promise<authResult>

  /** Deploy-time: create infrastructure (user pool, API keys, etc.) */
  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) =>
    Pulumi.Output.t<authConfig>
}
```

The `requestContext` is a minimal, transport-agnostic envelope:

```rescript
type requestContext = {
  headers: dict<string>,          // HTTP headers (both GraphQL and MCP use HTTP)
  sourceIp?: string,              // client IP address
  correlationId?: string,         // from X-Correlation-Id header or auto-generated
  userAgent?: string,             // useful for audit trails
}
```

### 3.3 Provider Implementations

#### In-Memory Provider

Simple, deterministic, no external dependencies. Two built-in identities cover the common development scenarios:

```rescript
// reventless-local/src/adapter/Auth/Auth_InMemory.res

let defaultUser: identity = {
  userId: "local-user",
  username: "user",
  groups: ["User"],
  provider: InMemory,
}

let adminUser: identity = {
  userId: "local-admin",
  username: "admin",
  groups: ["Admin", "User"],
  provider: InMemory,
}
```

**Switching between identities** via the `X-User` header:

| Header | Identity |
|--------|----------|
| *(none)* | `defaultUser` — normal development "just works" |
| `X-User: admin` | `adminUser` — test admin-only operations |
| `X-User: user` | `defaultUser` (explicit) |

For custom test scenarios (e.g., testing specific group combinations), the `X-Groups` header overrides the groups on either identity:

```
// Test a user with custom groups
fetch(url, { headers: { "X-User": "admin", "X-Groups": "Admin,Editor,Viewer" } })
```

No cryptographic verification — designed for local development and integration tests.

#### AWS Cognito Provider

Validates JWT tokens from Cognito User Pools:

```rescript
// reventless-aws/src/adapter/Auth/Auth_Cognito.res

// Deploy-time: creates or references a Cognito User Pool
// Runtime: validates JWT, extracts claims, maps cognito:groups to identity.groups
```

- Reuses the existing `Config.userPool` and `Config.userPoolId` fields
- JWT validation via `aws-jwt-verify` (already battle-tested for Lambda@Edge)
- Maps `cognito:groups` claim → `identity.groups`
- Maps `sub`, `cognito:username`, and custom attributes → `identity`

#### Future Providers (Out of Scope, But Enabled by Abstraction)

- **Auth0**: JWKS-based JWT validation, `permissions` claim → groups
- **Azure AD**: MSAL token validation, `roles` claim → groups
- **API Key**: Simple key lookup with pre-assigned identity (for service-to-service)

---

## 4. Authorization Model

### 4.1 Declarative Permission Rules

Replace the current `authorization = { tableName, group }` (which is AppSync-specific) with a generalized model:

```rescript
// reventless-spec/src/types/Authorization.res

type permission =
  | AllowGroups(array<string>)         // any of these groups may access
  | AllowAuthenticated                 // any authenticated user
  | AllowAnonymous                     // public access (no auth required)
  | DenyAll                            // explicitly blocked

type rule = {
  resource: string,                    // field name, resource URI, or "*"
  permission: permission,
}
```

### 4.2 Type-Safe Groups

The framework's `permission` type uses `array<string>` for maximum flexibility. To prevent typos and get exhaustiveness checks, applications define a `group` variant type with a typed helper.

**Where to define the group type?**

| Location | Pros | Cons |
|----------|------|------|
| Platform config | Composition root | Plugins defined before platform functor — can't reference it |
| Dedicated shared spec package | All plugins can depend on it | New package just for a few types |
| Inline in each plugin | No shared dependency | Inconsistent group names across plugins |

**Recommended: Platform config module** with a helper function. Plugin specs are defined before the platform functor runs, so they can't directly reference the platform's `group` type. However, the platform config module (e.g., `MyPlatformConfig.res`) can be a plain module that plugins import — it doesn't need to be inside the platform functor.

```rescript
// my-app/src/AppGroups.res — shared across all plugins and platform config

@schema
type group =
  | Admin
  | Editor
  | Viewer
  | Customer

// Typed helper — converts group variants to AllowGroups(array<string>)
let allow = (groups: array<group>): permission =>
  AllowGroups(groups->Array.map(S.reverseConvertOrThrow(_, groupSchema)))
```

Sury's default variant encoding serializes `Admin` as `"Admin"` — no `@as` annotations needed.

**If a reusable User Management Plugin is introduced later** (see Section 7), it would need to work with any application's group type. This means the plugin must be generic over groups — it would accept a `groupSchema: S.t<'group>` parameter rather than hardcoding group variants. The application's `AppGroups.group` type would be passed in when wiring the plugin. This is another reason to keep `permission` as `array<string>` in the framework — the User Management Plugin can work with any group type that serializes to strings.

### 4.3 Spec-Level Authorization

Plugin authors declare authorization in their specs rather than in handler code:

**For Aggregates (mutations):**

```rescript
open AppGroups

module MySpec: Aggregate.Spec = {
  // ...existing spec fields...

  let authorization = allow([Admin, Editor])
  // Or per-command:
  let commandAuthorization = command =>
    switch command {
    | Create(_) => allow([Admin])
    | Update(_) => allow([Admin, Editor])
    | View(_) => AllowAuthenticated
    }
}
```

**For ReadModels (queries):**

```rescript
open AppGroups

module MyReadModelSpec: ReadModel.Spec = {
  // ...existing spec fields...

  let authorization = AllowAuthenticated
  // Or per-index:
  let indexAuthorization = index =>
    switch index {
    | "publicIndex" => AllowAnonymous
    | _ => allow([Viewer, Editor, Admin])
    }
}
```

**For DCB Slices:**

```rescript
open AppGroups

module MySliceSpec: StateChangeSlice.Spec = {
  // ...existing spec fields...

  let authorization = allow([Admin])
}
```

### 4.4 Authorization Enforcement Points

Authorization is enforced at the API gateway level (GraphQL resolver / MCP handler), **not** inside domain logic. This keeps behaviors pure and authorization testable independently.

```
Client Request
  │
  ├─ Authentication (extract identity from token/headers)
  │
  ├─ Authorization (check identity.groups against spec's permission rules)
  │     │
  │     ├─ Denied → return 403/error
  │     └─ Allowed → continue
  │
  └─ Handler execution (CommandGenerator / QueryDb read)
        │
        └─ identity flows into Message.meta for audit trail
```

### 4.5 How This Maps to Existing Providers

| Concept | AWS (Current) | AWS (New) | In-Memory |
|---------|---------------|-----------|-----------|
| Authentication | Cognito JWT via AppSync | Cognito JWT validated in resolver middleware | Header-based or open |
| Mutation auth | None | Check `commandAuthorization` before dispatch | Same check |
| Query auth | `@aws_auth` directive | Check `authorization` before query | Same check |
| MCP tool auth | None | Check `commandAuthorization` before tool call | Same check |
| MCP resource auth | None | Check `authorization` before resource read | Same check |

For AWS AppSync specifically, the `@aws_auth` directive injection can remain as an **optimization** — AppSync enforces it at the gateway level before Lambda is even invoked. The generalized check acts as a fallback for non-AppSync transports (Lambda Function URL for MCP, future REST API).

---

## 5. Integration with GraphQL

### 5.1 graphql-yoga (In-Memory)

graphql-yoga supports a `context` factory that runs per-request. This is the natural injection point:

```rescript
let yoga = createYoga({
  "schema": schema,
  "context": async (req) => {
    let identity = await authProvider.authenticate(extractRequestContext(req))
    {"identity": identity}
  },
})
```

The resolver function signature changes from `(JSON.t, JSON.t) => promise<JSON.t>` to include context:

```rescript
type resolverFn = (JSON.t, JSON.t, resolverContext) => promise<JSON.t>
type resolverContext = { identity: authResult }
```

Each resolver checks authorization before executing:

```rescript
let resolver: resolverFn = async (_root, args, ctx) => {
  switch authorize(ctx.identity, spec.commandAuthorization(command)) {
  | Denied(reason) => raiseGraphQLError(reason)
  | Allowed(identity) =>
    let payload = {
      command,
      arguments: args->Obj.magic,
      meta: { ip: [], user: identity.username, info: `Mutation.${field}` },
    }
    // ...execute command
  }
}
```

### 5.2 AWS AppSync

AppSync handles authentication natively and passes identity in the Lambda event context. The adapter extracts it:

```rescript
// Runtime: Lambda event contains identity from Cognito
let extractIdentity = (event: lambdaEvent): identity => {
  userId: event.identity.sub,
  username: event.identity.username,
  groups: event.identity.claims.cognito_groups,
  provider: Cognito,
  issuer: event.identity.issuer,
  claims: Dict.fromArray([
    ("email", event.identity.claims.email),
    ("email_verified", event.identity.claims.email_verified),
  ]),
}
```

The existing `@aws_auth` directive injection continues to work for coarse-grained group checks. Fine-grained per-command authorization runs inside the Lambda resolver.

### 5.3 Schema Directives (Informational)

The stitched SDL can include authorization metadata as custom directives for introspection tooling:

```graphql
directive @auth(groups: [String!]) on FIELD_DEFINITION

type Mutation {
  createItem(id: ID!, name: String!): String!
    @auth(groups: ["Admin", "Editor"])
  deleteItem(id: ID!): String!
    @auth(groups: ["Admin"])
}
```

This is informational only — enforcement happens in the resolver layer, not via directive processing.

---

## 6. Integration with MCP

### 6.1 Transport-Level Authentication

Both in-memory and AWS MCP servers use **Streamable HTTP**. Authentication plugs in at the HTTP request handler level, before the MCP protocol processes the message:

```rescript
// MCP request handler (both platforms)
let handleRequest = async (req, res) => {
  let identity = await authProvider.authenticate(extractRequestContext(req))
  switch identity {
  | AuthError(msg) => res->sendStatus(401, msg)
  | Anonymous if requiresAuth => res->sendStatus(401, "Authentication required")
  | identity =>
    // Pass identity into MCP server context for per-tool/resource authorization
    let mcpServer = createServerWithContext(identity)
    mcpServer->handleRequest(req, res)
  }
}
```

### 6.2 Per-Tool and Per-Resource Authorization

MCP tools map to mutations, MCP resources map to queries. The same authorization rules apply:

```
MCP Tool "CatalogPlugin_CreateItem" → commandAuthorization(CreateItem) → AllowGroups(["Admin"])
MCP Resource "catalogplugin/items/{id}" → authorization → AllowAuthenticated
```

The `CallTool` handler checks authorization before dispatching:

```rescript
// Inside MCP tool handler
let handleToolCall = async (toolName, args, identity) => {
  let auth = lookupToolAuthorization(toolName)
  switch authorize(identity, auth) {
  | Denied(reason) => McpError(reason)
  | Allowed(_) => executeCommand(toolName, args, identity)
  }
}
```

### 6.3 MCP OAuth 2.0 Flow (Future)

The MCP specification (2025-03-26) defines an OAuth 2.0 authorization flow. When a client connects:

1. Server advertises auth requirements in the `initialize` response
2. Client obtains token via OAuth (Cognito hosted UI, Auth0, etc.)
3. Client sends token in `Authorization: Bearer <token>` header on Streamable HTTP requests

This aligns naturally with the `Auth_Adapter.Provider` abstraction — the same JWT validation logic handles both GraphQL and MCP requests.

---

## 7. User Management

### 7.1 Reventless-Managed vs External IdP

Two strategies, not mutually exclusive:

**Strategy A: External IdP (Recommended Default)**

The identity provider lives outside Reventless. Cognito, Auth0, or Azure AD manages users, passwords, MFA. Reventless only validates tokens and reads claims.

- Pros: No user management code to write, battle-tested security, SSO support
- Cons: Dependency on external service, limited customization

**Strategy B: Reusable User Management Plugin**

A framework-provided, reusable plugin (similar to `Platform_Admin`) that models users and groups as event-sourced aggregates. Unlike Strategy A, the domain model for users lives inside Reventless — giving full control and audit trails.

**Scope**: User/group CRUD and assignment — **not** authentication primitives (passwords, MFA, token issuance). Authentication still delegates to an `Auth_Adapter.Provider`. The User Management Plugin manages the *authorization* side: who exists, what groups they belong to, and what permissions those groups grant.

```
Aggregates:
  User:  CreateUser, UpdateUser, DeactivateUser, ReactivateUser
         → UserCreated, UserUpdated, UserDeactivated, UserReactivated
  Group: CreateGroup, RenameGroup, DeleteGroup
         → GroupCreated, GroupRenamed, GroupDeleted

Commands (cross-aggregate):
  AssignUserToGroup, RemoveUserFromGroup
  → UserAssignedToGroup, UserRemovedFromGroup

ReadModels:
  Users        — queryable by group, email, status
  Groups       — list all groups with member counts
  UserGroups   — groups for a specific user (used by auth enforcement)
```

**Generic over the application's group type**: The plugin accepts a `groupSchema: S.t<'group>` so it works with any application's `AppGroups.group` variant. This is why the framework's `permission` type uses `array<string>` — the User Management Plugin serializes group variants to strings for storage and comparison.

```rescript
// Wiring in the application's platform config
module UserMgmt = UserManagementPlugin.Make(Platform, {
  let groupSchema = AppGroups.groupSchema
  let initialGroups = [Admin, Editor, Viewer, Customer]
})
```

**How it interacts with external IdPs**: The plugin can run *alongside* an external IdP. Two patterns:

1. **IdP as source of truth**: External IdP manages users/groups. The plugin syncs via events (Cognito post-confirmation trigger → command) for audit and local querying. Groups in the IdP and in the plugin stay in sync.

2. **Plugin as source of truth**: The plugin manages groups and user-group assignments. An automation slice pushes group changes to the external IdP (e.g., Cognito `AdminAddUserToGroup`). The IdP is a downstream projection.

**Recommendation**: Start with Strategy A (external IdP). Design the `Auth_Adapter.Provider` and `permission` types so Strategy B can be added later as an optional plugin without changing any existing plugin specs or authorization rules. The `allow([Admin, Editor])` syntax works identically whether groups come from Cognito claims or from the User Management Plugin's read model.

### 7.2 Group/Role Management

Whether using external IdP or built-in user management, groups flow through the same path:

```
IdP or UserManagement Plugin → identity.groups → authorization check
```

The source of group membership is an implementation detail hidden behind `Auth_Adapter.Provider`. Plugin specs reference groups via the typed `allow()` helper (Section 4.2) — they never know or care where group data comes from.

### 7.3 Platform-Level Configuration

The platform config gains an auth section:

```rescript
open AppGroups

module Config = {
  // ...existing config...

  module Auth = {
    // Which provider to use
    let provider: module(Auth_Adapter.Provider) = module(Auth_Cognito)

    // Default permission for operations without explicit authorization
    let defaultPermission = AllowAuthenticated

    // Admin group (type-safe via AppGroups.group)
    let adminGroup = Admin
  }
}
```

---

## 8. Client Experience

### 8.1 Authentication Flow (Client Perspective)

```
1. Client authenticates with IdP
   ├─ Cognito: Hosted UI, SDK (Amplify), or API (InitiateAuth)
   ├─ Auth0: Universal Login or SDK
   └─ In-Memory: Set X-User/X-Groups headers (dev only)

2. Client receives JWT (id_token or access_token)

3. Client sends JWT with every request
   ├─ GraphQL: Authorization: Bearer <token>
   └─ MCP: Authorization: Bearer <token> (Streamable HTTP)

4. Server validates token, extracts identity, enforces authorization
```

### 8.2 Client SDK Considerations

For the best client experience:

- **Single token** works for both GraphQL and MCP — no separate auth flows
- **Token refresh** is handled client-side (Cognito SDK, Amplify, etc.)
- **Error responses** use standard HTTP 401/403 codes (not GraphQL errors for auth failures at the transport level)
- **Introspection** can expose `@auth` directives so clients can proactively hide unauthorized operations in their UI

### 8.3 Service-to-Service Authentication

For inter-plugin or automated access (e.g., automation slices triggering commands):

- **In-Memory**: System identity with all groups (trusted internal calls)
- **AWS**: IAM role-based authentication (Lambda execution role) or Cognito machine-to-machine credentials (client_credentials grant)
- The `Auth_Adapter.Provider` can recognize IAM-signed requests as a special identity type

---

## 9. Implementation Approach

### Phase 1: Core Types & In-Memory Provider
- Define `Identity`, `authResult`, `permission`, `rule` types in `reventless-spec`
- Implement `Auth_InMemory` provider (header-based)
- Add `resolverContext` to graphql-yoga setup
- Wire authorization checks into `CommandGeneratorResolvers_GraphQL` and `QueryDbResolvers_GraphQL`
- Add `authorization` fields to `Aggregate.Spec` and update `ReadModel.Spec`'s existing authorization type

### Phase 2: MCP Authorization
- Add auth middleware to `MCP_Server.res` (in-memory) and `MCP_ServerInstance.res`
- Map tool/resource authorization from spec rules
- Test with header-based in-memory provider

### Phase 3: AWS Cognito Provider
- Implement `Auth_Cognito` provider (JWT validation)
- Extract identity from AppSync Lambda event context
- Extract identity from MCP Lambda Function URL requests
- Keep `@aws_auth` directive injection as an AppSync optimization layer

### Phase 4: Spec Extensions
- Add optional `commandAuthorization` to aggregate specs
- Add optional `authorization` to DCB slice specs
- Update `GraphQL_FragmentGenerator` and `MCP_SchemaGenerator` to include auth metadata
- Update platform-and-plugin-guide documentation

---

## 10. Open Questions

1. **Granularity**: Should authorization be per-command (most flexible) or per-aggregate/per-slice (simpler)? Recommendation: support both — per-aggregate as default, per-command as opt-in.

2. **Row-level security**: Should read model queries filter results by user identity (e.g., "users can only see their own orders")? This is fundamentally different from endpoint-level authorization and may need a separate mechanism (query filters / row-level policies). Out of scope for this initial design.

3. **Token type**: `id_token` vs `access_token`? For Cognito, `id_token` carries `cognito:groups`. For OAuth2 best practices, `access_token` with scopes is preferred. The adapter abstraction supports both — provider implementations decide.

4. **Admin API separation**: The current `splitApi` config separates admin schema from plugin schemas. Should admin operations require a different auth level (e.g., `AdminGroup` only)? Current behavior already restricts admin to `["Admin"]` group via `@aws_auth`. The new model should preserve this.

