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

### A1. Define the auth abstraction types

- In `reventless/reventless-spec/src/types/`:
  - Verify `Identity.res` exposes the expected shape `{userId, username, groups, claims?, provider}` — it should already (see the abstraction reference).
  - Add `permission` variant (`AllowGroups / AllowAuthenticated / AllowAnonymous / DenyAll`) and `authResult` (`Authenticated(identity) | Anonymous | AuthError(string)`).
- Define `Auth_Adapter.Provider` module type in `reventless/reventless-core/src/adapter/Auth/Auth_Adapter.res` — `authenticate: requestContext => promise<authResult>` plus a deploy-time `make`. See the abstraction reference for the exact module-type signature.

**Verify:** `pnpm run build` from root passes with zero warnings.

### A2. Implement `Auth_InMemory.authenticate` (header-based)

- Create `reventless/reventless-in-memory/src/adapter/Auth/Auth_InMemory.res` implementing `Auth_Adapter.Provider`.
- Extraction order: `X-User: alice|admin|…` → identity from configured users; `X-Groups: A,B,C` → overrides groups on the resolved identity; neither → `Identity.anonymous`.
- Wire as the graphql-yoga `context` factory in `reventless/reventless-in-memory/src/adapter/DomainGraphQL_Server.res`. Resolvers receive `ctx.identity`.

**Verify:** `curl -H 'X-User: admin' …` produces a request whose resolver sees `ctx.identity.groups = ["Admin"]`. A unit test on `Auth_InMemory` covers the extraction matrix.

### A3. Spec-level authorization on one example

- Add `commandAuthorization` (optional) to `Aggregate.Spec` and `authorization` (optional) to `ReadModel.Spec`. See the abstraction reference for the spec-level authorization conventions.
- Enforce at resolver entry: in `CommandGeneratorResolvers_GraphQL` (in-memory) and `QueryDbResolvers_AppSync` (AWS) — wrap dispatch with `authorize(ctx.identity, rule)`. **Keep the diff symmetric across both transports** — divergence between the in-memory and AWS resolver paths is a recurring source of bugs.
- Apply to one example aggregate in `examples/online-shop-hybrid/catalog/` and one read model. Use the syntax `let commandAuthorization = _ => AllowGroups(["Admin"])` for the simplest case.

**Verify:** test a header-driven `X-User: admin` request to the restricted mutation succeeds; `X-User: alice` (non-Admin) is rejected with a 403-equivalent GraphQL error.

### A4. Token issuance: `Auth_InMemory.Login` + YAML store

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
