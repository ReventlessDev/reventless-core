# Plan: Host UI Login — Core

**Abstraction reference:** `reventless-core: docs/analysis/authentication-authorization.md` — the provider-agnostic `Auth_Adapter.Provider` / `Identity.t` / `permission` model. This plan implements that abstraction and adds the in-memory login endpoint, Cognito infra, and AppSync auth mode flip on top.
**Sibling plan:** `reventless-ui: docs/plans/host-ui-login-ui.md` — SPA AuthProvider, LoginPage, UserMenu, Cognito SDK call.
**Prerequisite:** `reventless-core: docs/plans/cloudfront-ui-fragments-core.md` steps 1-4 (host shell needs somewhere to live and a `Platform_UIFragments` query to call) are recommended before Stage D step 11 of the sibling UI plan, but Stage A of this plan can run independently.

## Scope

Core-side work: define and implement the auth abstraction, provision Cognito infrastructure, flip AppSync to Cognito-backed auth, add the in-memory login endpoint + YAML user store. The SPA shell is in the UI sibling plan.

Each stage has a verification gate; do not advance until it passes. Stage B is entirely UI-side (see sibling plan); this plan covers A / C / D / E.

## Stages overview

- **Stage A** — Abstraction + in-memory baseline (no AWS work).
- **Stage B** — SPA shell against in-memory (entirely UI-side; see sibling plan).
- **Stage C** — Cognito UserPool provisioning (no behaviour change).
- **Stage D** — Wire Cognito into AppSync.
- **Stage E** — Spec-level authz parity on AWS (optional).

## Stage A — Abstraction + in-memory baseline (no AWS work)

### A1. Define the auth abstraction types — ✅ done

**Commit:** `a273c10d4`

- `reventless-spec/src/types/Identity.res` — added `authResult` variant (`Authenticated(t) | Anonymous | AuthError(string)`). Existing `t` already matched the expected shape.
- `reventless-spec/src/types/Authorization.res` (new) — `permission` variant (`AllowGroups(array<string>) | AllowAuthenticated | AllowAnonymous | DenyAll`) plus `isAllowed: (permission, Identity.t) => bool` helper.
- `reventless-core/src/adapter/Auth/Auth_Adapter.res` (new) — `requestContext` envelope (`{headers, sourceIp?, correlationId?, userAgent?}`) and `Provider` module type with abstract `authConfig`, `authenticate: requestContext => promise<Identity.authResult>`, deploy-time `make: (~name, ~opts=?) => Pulumi.Output.t<authConfig>`.

### A2. Implement `Auth_InMemory.authenticate` (header-based) — ✅ done

**Commit:** `fe7005204` (no-header tweak baked into commits `fe7005204` and `dd188ee86`).

- `reventless-in-memory/src/adapter/Auth/Auth_InMemory.res` — built-in `defaultUser` (groups: `["User"]`) + `adminUser` (groups: `["Admin", "User"]`); mutable user registry seeded with both; `registerUser`/`resetUsers` for tests. Header parsing case-insensitive (`X-User` / `X-Groups`).
- **Behavior decision (see [feedback memory](../../.claude/projects/-Users-martin-prj-ReventlessDev-reventless-core/memory/feedback_authz_default_and_in_memory_dev.md)):** no `X-User` header → `Authenticated(defaultUser)` (not `Anonymous`), so local dev "just works" against an `AllowAuthenticated`-defaulted backend. Anonymous is reachable only by explicit `Identity.anonymous`.
- `rescript-graphql-yoga/src/GraphqlYoga.res` — new `createYogaWithContext` binding (re-binds graphql-yoga's `createYoga` with the `context` option). Existing callers stay on the original binding.
- `reventless-in-memory/src/adapter/DomainGraphQL_Server.res` — `buildAuthContext` factory flattens Fetch API headers to a lowercase dict, calls `Auth_InMemory.authenticate`, attaches `ctx.identity`. Wired at both yoga instances (`start` + `rebuildSchema`).
- Tests: 7 cases on the extraction matrix in `tests/adapter/Auth_InMemoryTest.res`. Full in-memory suite: 383/383 pass.

### A3. Spec-level authorization, PPX-driven

> Split into A3.1 (PPX top-level annotation) → A3.2 (Spec module types + PPX inline-spec walk) → A3.3 (resolver enforcement) → A3.3b (per-constructor `@authorize`) → A3.5 (apply to example + integration tests). A3.4 (Auth_InMemory no-header tweak) folded into A2.

The mechanism is declarative via PPX annotations — framework default is `AllowAuthenticated`, override with file-level `@@reventless.authorize(<rule>)`:

```rescript
@@reventless.spec
@@reventless.authorize(AllowGroups(["Admin"]))   // whole aggregate

@schema type command = …
```

Per-constructor `@authorize(<rule>)` on `type command` variants is planned for A3.3b (right after resolver enforcement lands).

#### A3.1 — PPX file-level annotation + auto-inject defaults — ✅ done

**Commit:** `dd188ee86`

- `reventless-ppx/src/ppx/AuthorizationInjection.ml` (new) — folder-based detector (`Aggregate/`, `*StateChangeSlice*`, `*InboundTranslationSlice*` → command-carrier; `ReadModel/`, `*StateViewSlice*`, `*StateViewSliceStream*` → query-carrier); generators for `let commandAuthorization = _ => <rule>` and `let authorization = <rule>`; payload extraction from `@@reventless.authorize(<expr>)`; idempotent on bodies already declaring the binding.
- `reventless-ppx/src/ppx/ReventlessPpx.ml` — `transform`'s `Spec` mode calls `AuthorizationInjection.inject` after the existing prefix/body/suffix assembly.
- Framework default rule `Reventless.Authorization.AllowAuthenticated` emitted fully qualified — `open Reventless.Authorization` is only added when the file's payload uses unqualified constructors (avoids "unused open" warnings on every spec).
- PPX binaries rebuilt: `ppx-osx-x64.exe`, `ppx-linux.exe` (Docker amd64). 179/179 PPX integration tests pass.

#### A3.2 — Spec module types + PPX inline-spec walk + framework hand-edits — ✅ done

**Commit:** see the final A3 squash (PPX inline-spec walk + Spec module types + deep-inline framework edits).

- **Spec module types** now declare the authorization field:
  - `Aggregate.Spec`, `StateChangeSlice.Spec`, `InboundTranslationSlice.Spec` → `let commandAuthorization: command => Authorization.permission`
  - `ReadModel.Spec`, `StateViewSlice.Spec` → `let authorization: Authorization.permission`
- **PPX inline-spec walk** — `AuthorizationInjection.walk_inline_specs` runs unconditionally at the start of `transform`. Structural detection of aggregate-shaped (`@schema type command`) and read-model-shaped (`@schema type state` + `let subIdConfig`) inner modules → injects `commandAuthorization` / `authorization` with the framework default. Eliminates the boilerplate for all 23-ish test fixtures and any `@@reventless.spec` file in unconventional locations (e.g. `src/admin/PluginSpec.res`).
- **Spec-namespace packages skipped** — `CatalogSpec`, `OrderingSpec` etc. don't depend on reventless-spec, so injection (which references `Reventless.Authorization`) would not resolve there. The framework spec packages don't need the field because the types they declare (ExtensionPoint protocols, etc.) satisfy module types that don't require authorization.
- **Top-level structural fallback** — `detect_kind_by_structure` handles `@@reventless.spec` files outside the folder convention (e.g. `src/admin/PluginSpec.res`).
- **`transform_delegate_module` extended** — Delegate modules inside ExtensionPointMapping files get a `let commandAuthorization` stub alongside the auto-injected `Id`/`command`/`error`/`moduleUrl`.
- **Hand-edits for `Pexp_letmodule` cases** — modules defined inside `let … = () => { module Foo = … }` function bodies are at AST positions the PPX walk doesn't reach. Eight framework files get an explicit one-liner: `Counter_Builder`, `Inbound/Outbound/AutomationSlice_Builder`, `StateViewSlice_Builder` (reads `Spec.authorization`), `infra/types/ExtensionMapping.NoDelegate`, plus 2 test fixtures (`QueryDbListResolverTest`, `InboundTranslationSliceCallbackTest`).

After A3.2: full monorepo builds clean, 383/383 in-memory tests still pass, 179/179 PPX tests still pass. Roughly 120 `.res.mjs` downstream regenerations.

#### A3.3 — Resolver enforcement (in-memory) — ✅ done

- **Hook signature** — `Plugin_Helpers.platformHooks.mutationResolverHook` now takes `~commandAuthorization: unknown => Authorization.permission`. Threaded from `Plugin_Builder` (aggregate path, `M.Spec.commandAuthorization`) and `Dcb_Builder` (DCB sync + async slices, `S.Spec.commandAuthorization`). In-memory `Platform.res` forwards into `register` / `registerDcb`.
- **Mutation resolvers** (`CommandGeneratorResolvers_GraphQL`) — synthesize a TAG-shaped command value per call (`{TAG: commandName}`), evaluate `commandAuthorization`, short-circuit with a `CommandRejected` outcome (`errorCode: "Forbidden"`, fresh msgId from `Message.uuid()`) when `Authorization.isAllowed(rule, identity)` is `false`. The dead `X-Identity` JSON-header parse was replaced by reading `ctx.identity` directly — `DomainGraphQL_Server.buildAuthContext` populates it via `Auth_InMemory.authenticate`. **A3.3b ready**: the synthetic value only carries the variant TAG, which is sufficient for the per-constructor `switch command { … }` the PPX will emit (record-payload-only constructors get GraphQL fields; payload-less variants are filtered out of `extractVariantNames`).
- **Query resolvers** (`QueryDbResolvers_GraphQL`) — `QueryDb_Adapter.resolversMaker` gained `~authorization: Authorization.permission`; `QueryDb_Builder.Make` passes `Spec.authorization`; the in-memory resolver runs `Authorization.isAllowed(authorization, identity)` ahead of the existing `queryInterceptorHook`, returning `Deny("Forbidden")` on failure (each resolver already maps `Deny(_)` to an empty connection / null payload, so no SDL change is needed).
- **AWS counterparts** — `QueryDbResolvers_AppSync`, `QueryDbResolvers_AppSync_NoOp`, and `QueryDbResolvers_NoOp` accept `~authorization` as a no-op (AWS path will enforce via `@aws_auth(cognito_groups: …)` in Stage E). Keeps the maker signatures aligned across in-memory and AWS without changing AWS behavior.
- **Test fixture** — `tests/adapter/QueryDbListResolverTest.res` `emptyCtx` now carries a synthetic authenticated identity (`{userId: "test-user", groups: ["User"]}`) so the pagination-mechanics tests pass the new `AllowAuthenticated` check.

Verified: full monorepo build clean (zero warnings), 383/383 in-memory tests pass, 179/179 PPX tests pass.

#### A3.3b — Per-constructor `@authorize` annotation — pending

Walk `@schema type command` constructors, build a `switch command { … }` that maps each constructor to its `@authorize(rule)` payload (or the file-level default). Wholly inside `AuthorizationInjection.ml`; the resolver code path doesn't change.

#### A3.5 — Apply to catalog example + integration test — pending

- `examples/online-shop-hybrid/catalog/src/Category/Aggregate/Category.res` — `@@reventless.authorize(AllowAuthenticated)` (matches the default — explicit) plus `@authorize(AllowGroups(["Admin"]))` on the `Archive` constructor.
- `examples/online-shop-hybrid/catalog/src/Category/ReadModel/Categories.res` — `@@reventless.authorize(AllowAuthenticated)`.
- Integration test: `X-User: admin` succeeds against Archive; `X-User: user` returns a 403-equivalent GraphQL error.

**Verify (whole A3):** `curl -H 'X-User: admin' …` on the restricted mutation succeeds; `X-User: user` (or no header, which yields `defaultUser` with only the `User` group) is rejected at the resolver boundary.

### A4. Token issuance: `Auth_InMemory.Login` + YAML store — pending

This is the only Stage A step that goes beyond the abstraction reference (which only specifies validation, not issuance).

- Extend `Auth_InMemory` with a `Login` submodule:
  ```rescript
  module Login = {
    let issue: (~username: string, ~password: string) => promise<result<string, string>>
  }
  ```
  Token format: base64(JSON(`Identity.t`)) + "." + HMAC-SHA256(payload, secret). Secret = per-process random or `Platform.Make(~tokenSecret=…)`.
- Extend `Auth_InMemory.authenticate` to recognise `Authorization: Bearer <token>` alongside the existing `X-User`/`X-Groups` paths. Decoding order: Bearer (if HMAC valid) → `X-User`/`X-Groups` → anonymous.
- User store loader at `reventless/reventless-in-memory/src/adapter/Auth/UserStore.res`:
  - Resolution order at `Platform.Make`: `~users` arg → `~usersFile` arg → `.reventless/users.yaml` relative to `process.cwd()` → empty (login rejects all, one-line stdout hint).
  - YAML parsing: depend on a small yaml package (e.g. `js-yaml`) — add to the in-memory package only, not framework-wide.
  - Type: `array<{username: string, password: string, groups: array<string>}>`.
- Attach two HTTP endpoints to the existing graphql-yoga handler:
  - `POST /__inmemory/login` body `{username, password}` → `{token, identity}` on success, 401 with `{error}` on failure.
  - `POST /__inmemory/logout` always 204 no-content.

**Verify:**
1. Create `.reventless/users.yaml` with two users.
2. `curl -X POST .../__inmemory/login -d '{"username":"alice","password":"alice"}'` returns a token.
3. `curl -H 'Authorization: Bearer <token>' …` produces the same `ctx.identity` shape as `X-User: alice` did in A2.
4. `Platform.Make(~users=[…])` works without touching disk — used by a new test in `reventless-in-memory/tests/`.

> **Stage A gate:** in-memory platform supports both header-based and form-based identity; resolvers enforce per-spec authorization; no AWS changes yet.

> **Hand-off to UI sibling plan:** Stage A complete unblocks UI sibling plan Stage B (the SPA shell can drive against the `POST /__inmemory/login` endpoint locally).

## Stage C — Cognito UserPool provisioning (no behaviour change)

(Stage B is entirely UI-side; see sibling plan.)

### C1. Resolve UserPool via Pulumi config (BYO or auto)

Add a `Platform_Stack.resolveCognitoUserPool()` helper in `reventless/reventless-aws/src/Platform_Stack.res`.

- Read `platform:cognitoUserPoolId` from `Pulumi.Config.make(Some("platform"))`.
- **BYO branch** (config set): skip pool creation; create a `UserPoolClient` inside the existing pool with SPA settings; look up ARN via `aws.cognito.getUserPool({userPoolId})` data source.
- **Auto branch** (config absent): create `UserPool` + `UserPoolClient`. UserPool config:
  ```
  adminCreateUserConfig: { allowAdminCreateUserOnly: true }
  usernameAttributes: ["email"]
  passwordPolicy: { minimumLength: 12, requireLowercase, requireUppercase, requireNumbers }
  mfaConfiguration: "OFF"
  ```
  Client config (both branches): `generateSecret: false`, `explicitAuthFlows: ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]`, `preventUserExistenceErrors: "ENABLED"`, id/access TTL = 60min, refresh TTL = 30 days.
- The framework **always** owns the client (even in BYO mode) — needs specific SPA settings that wouldn't reliably exist on a pre-existing client. The client is a child resource Pulumi can destroy without touching the parent pool.
- Returns `{poolId, clientId, poolArn, managed: bool}` — all `Pulumi.Output.t`.
- Wire from `examples/online-shop-hybrid/platform-aws/src/Main.res` — call `resolveCognitoUserPool` and forward the outputs.

**Caller responsibilities (BYO path):** the existing pool must already have its groups created manually (`Admin`, `Catalog`, …); the framework never creates users or groups.

### C2. Stack outputs

Export from the platform stack:
- `cognitoUserPoolId`
- `cognitoUserPoolClientId`
- `cognitoUserPoolArn`
- `cognitoRegion`
- `cognitoUserPoolManaged` (string `"true"`/`"false"` — operational metadata)

**Verify:**
1. No config: `pulumi up` creates pool + client; outputs populated; `aws cognito-idp admin-initiate-auth` against a manually-created user succeeds.
2. `pulumi config set platform:cognitoUserPoolId …` + new stack: no pool created, only a client inside the existing pool; outputs reflect the BYO ID and the looked-up ARN.

> **Stage C gate:** Cognito pool exists and issues tokens; AppSync still uses `AWS_IAM`; nothing in production paths consumes the tokens yet.

## Stage D — Wire Cognito into AppSync

### D1. Implement `Auth_Cognito.authenticate`

- Create `reventless/reventless-aws/src/adapter/Auth/Auth_Cognito.res` implementing `Auth_Adapter.Provider`.
- Lambda runtime: extract identity from AppSync event context — `event.identity.sub` (→ `userId`), `event.identity.username` (→ `username`), `event.identity.claims['cognito:groups']` (→ `groups`), claims, `event.identity.issuer`. Reference implementation: `reventless/reventless-aws/src/adapter/Mcp/MCP_Lambda.res:350-385`.
- Recognise IAM auth path (`event.identity.userArn` for server-to-server) as a separate identity type — return `Identity.t` with a synthetic `provider: Custom("aws-iam")` and the role ARN as `userId`.

**Verify:** unit test parses representative Cognito event + IAM event payloads, produces correct `Identity.t`.

### D2. Switch AppSync `authenticationType`

- Edit `reventless/reventless-aws/src/components/Api/AppSync_Adapter.res:232`:
  ```rescript
  authenticationType: AppSync.GraphQLApi.AMAZON_COGNITO_USER_POOLS->Pulumi.Input.make,
  userPoolConfig: Some({
    userPoolId: cognitoUserPoolId->Pulumi.Input.asInput,
    awsRegion: region->Pulumi.Input.asInput,
    defaultAction: "DENY",
  }),
  additionalAuthenticationProviders: Some([
    { authenticationType: "AWS_IAM" },
  ]),
  ```
- Apply to all three API call sites: `domainApi`, `platformApi`, `eventsApi`.
- Re-verify the QueryDb resolver interceptor at `reventless/reventless-aws/src/components/Api/QueryDbResolvers_AppSync.res:25-58` correctly distinguishes Cognito identity from IAM identity (it already handles both — confirm).
- Server-to-server lambdas (heartbeat, Plugin_Connected emission) explicitly sign their AppSync calls with IAM via the existing IAM role.

**Verify:**
1. Unauthenticated curl to the GraphQL endpoint returns 401.
2. Curl with a valid Cognito id-token from C2 returns the expected payload.
3. Heartbeat lambda still publishes `PluginHeartbeat` events (signed via IAM, traverses the additional-provider path).
4. Plugin_Connected emission still works.

> **Stage D gate:** AWS deployments enforce Cognito auth end-to-end. In-memory unaffected. UI sibling plan step 11 can now switch the SPA to AWS mode.

## Stage E — Spec-level authz parity on AWS (optional)

### E1. Apply authorization declarations across the example domain

- Same as A3, but applied to all aggregates and read models in `examples/online-shop-hybrid/`. On AWS, these feed the existing `@aws_auth(cognito_groups: …)` directive injection — already coded but only newly *effective* after Stage D.

### E2. `requiredAccess` server-side enforcement

- In the SDL stitcher and `Plugin.makeAutoUIManifest`, lift `requiredAccess: Some("Admin")` from each panel/page into `@aws_auth(cognito_groups: ["Admin"])` on the corresponding mutation/query fields.
- This is the only server-side change beyond the abstraction reference. Can be deferred indefinitely if client-side filtering (UI plan step B6) is judged sufficient for the threat model.

**Verify:** a Cognito user not in the required group is rejected at the AppSync layer (before the resolver runs), regardless of what the UI sends.

## Out of scope for this plan

- `<AuthProvider>`, `<LoginPage>`, `<UserMenu>`, localStorage, Cognito SDK call — `reventless-ui: docs/plans/host-ui-login-ui.md`.
- Refresh-token rotation policy in the SPA — UI sibling plan.
- MCP authorization — see the abstraction reference; separate phase, parallel-safe.
- Auth0 / AzureAD / ApiKey provider implementations — see the abstraction reference (future).
- User Management Plugin — see the abstraction reference (future).
