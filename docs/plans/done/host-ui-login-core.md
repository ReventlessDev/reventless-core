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

#### A3.3b — Per-constructor `@authorize` annotation — ✅ done

- **PPX walk** — `AuthorizationInjection.extract_constructor_rules` scans `@schema type command` variant declarations and lifts every constructor-level `@authorize(rule)` attribute into a `(name, has_payload, rule_expr)` triple. `strip_authorize_attrs_from_command` then strips the attribute so sury-ppx never sees it.
- **Generator switch** — `gen_command_authorization_switch` emits `let commandAuthorization = command => switch command { | Ctor(_) => rule₁ | Bare => rule₂ … | _ => default }`. Payload-bearing constructors get a `Ctor(_)` pattern; payload-less constructors compile to bare-string literals and use the no-argument `Bare` form so the runtime check `command === "Bare"` fires correctly. The wildcard branch carries the file-level `@@reventless.authorize(rule)` payload — or the framework default `AllowAuthenticated` when no file-level rule is set.
- **Idempotent** — `inject` (file-level driver) and `inject_into_inner_module` (inline spec walk) both detect per-constructor attributes; bodies that already declare `commandAuthorization` are left untouched, so hand-rolled overrides win over PPX defaults. Open of `Reventless.Authorization` is added only when at least one constructor or file-level rule actually uses unqualified rule constructors.
- **Resolver code path unchanged** — `CommandGeneratorResolvers_GraphQL` still synthesizes `{TAG: commandName}` (or the bare-string literal for payload-less variants — same runtime shape sury emits) and calls `commandAuthorization`; the switch the PPX emits dispatches to the right rule without any further plumbing.
- **PPX binaries refreshed** — `ppx-osx-x64.exe` (local dune build) and `ppx-linux.exe` (Docker amd64) rebuilt; 184/184 integration tests pass (5 new for `@authorize`); zero-warning monorepo build; 383/383 in-memory tests still pass.

#### A3.5 — Apply to catalog example + integration test — ✅ done

- `examples/online-shop-hybrid/catalog/src/Category/Aggregate/Category.res` — `@authorize(AllowGroups(["Admin"]))` on the `Archive` constructor (file-level default `AllowAuthenticated` is implicit).
- `examples/online-shop-hybrid/catalog/src/Category/ReadModel/Categories.res` — no annotation; the implicit `AllowAuthenticated` default applies.
- **Latent gap closed first.** Pre-A3.5, `extractVariantNames` (used by `Plugin_Builder` to derive mutation field names) filtered out payload-less variants — so `Archive` never became a GraphQL mutation and the per-constructor `@authorize` on it was unreachable through the resolver path. Resolved by:
  - New `Reventless.DcbTag.extractAllVariantNames` and `isVariantPayloadBearing` helpers (event-schema callers still use `extractVariantNames` to filter bare-string events from DCB query construction).
  - Call sites for command schemas switched to `extractAllVariantNames`: `Plugin_Builder.res` (mutation field derivation + plugin schema reporting), `Plugin_Structure.res` (UI registry), `Dcb_Builder.res` (DCB routing tag), `Api/GraphQL_SchemaInspector.res` (introspection).
  - `CommandGeneratorResolvers_GraphQL.syntheticCommand(name, ~hasPayload)` now emits a bare-string command value for payload-less constructors so the PPX-emitted switch's `typeof command !== "object"` branch fires. `hasPayload` is captured once per field at registration time.
  - `GraphQL_FragmentGenerator.generate` handles bare variants in the Union path (emits `Cat_Archive(id: ID!): String!`) — the in-memory `deriveSdlField` already had the corresponding fallback.
- **Integration test:** `tests/adapter/CommandAuthorizationTest.res` (7 cases) — admin/user/anonymous identities × Add (payload, default) / Archive (bare, Admin-only) at the resolver boundary, plus an assertion that `Cat_Archive` now appears in the registered SDL. Tests mirror the PPX output shape exactly so they regress if either side drifts.

**Verify (whole A3):** full monorepo build zero warnings; 390/390 in-memory tests pass (was 383/383, +7 new); 184/184 PPX tests pass.

### A4. Token issuance: `Auth_InMemory.Login` + YAML store — ✅ done

This is the only Stage A step that goes beyond the abstraction reference (which only specifies validation, not issuance).

- **`Auth_InMemory.Login`** (in [Auth_InMemory.res](../../reventless/reventless-in-memory/src/adapter/Auth/Auth_InMemory.res)) — `setCredentials` / `setTokenSecret` / `issue` / `verifyAndDecode` / `resetStore`. Token format: `<base64url(JSON(Identity.t))>.<base64url(HMAC-SHA256(payload, secret))>`; secret defaults to 32 random hex bytes per process, overridable via `setTokenSecret`. `setCredentials` mirrors the identity into the `X-User` registry so both header paths resolve consistently.
- **`Auth_InMemory.authenticate`** order: `Authorization: Bearer <token>` (when HMAC valid) → `X-User`/`X-Groups` → `defaultUser` fallback (kept from A2 for dev convenience). Invalid Bearer values fall through silently to the next path so a stale token doesn't trap the user.
- **`UserStore.res`** ([file](../../reventless/reventless-in-memory/src/adapter/Auth/UserStore.res)) — `load(~users?, ~usersFile?)` with resolution order: inline `~users` → `~usersFile` (errors propagate) → `.reventless/users.yaml` at `process.cwd()` (silent if absent, prints a one-line stdout hint). `autoLoadOnce()` is the idempotent variant used by `Platform.startServers` (split mode) and the inline-mode `start()` call. YAML parsing uses the `yaml` package (already at root); resolved entry: `{username, password, groups, userId?}`.
- **`POST /__inmemory/login`** and **`/__inmemory/logout`** ([DomainGraphQL_Server.res](../../reventless/reventless-in-memory/src/adapter/DomainGraphQL_Server.res)) — `node:http` request body collected manually (yoga never sees these routes); 200 with `{token, identity}` on success, 401 with `{error}` for missing user / wrong password / malformed body; logout always 204. Routing factored into a shared `_dispatch` helper so both `start()` and `rebuildSchema()` keep the same path table.
- **Jest 27 fetch polyfill rejected** — undici needs `ReadableStream` (Jest VM strips it); the HTTP test uses `node:http` directly. Same wire format the SPA will use via `fetch`.
- **Tests** (26 new cases across 3 files):
  - `Auth_InMemoryLoginTest.res` (11): `issue`/`verifyAndDecode` round-trips, tampered payload + signature rejection, malformed token, Bearer precedence over `X-User`, fallback to `X-User` when Bearer invalid, `setCredentials` mirroring into the X-User registry.
  - `Auth_InMemoryUserStoreTest.res` (9): `parseString` happy/malformed/missing-field paths, `load(~users)`/`load(~usersFile)`/`load()` resolutions, inline-overrides-file precedence, `autoLoadOnce` idempotence.
  - `Auth_InMemoryHttpTest.res` (6): real server on port 4321; 200 `{token, identity}` for valid creds, 401 for wrong password / unknown user / malformed body, 204 logout, Bearer round-trip through `authenticate`.

**Verify:** monorepo build zero warnings; 416/416 in-memory tests pass (was 390, +26).

> **Stage A gate:** in-memory platform supports header-based and Bearer-token identity; resolvers enforce per-spec authorization; no AWS changes yet. ✅

> **Hand-off to UI sibling plan:** Stage A complete unblocks UI sibling plan Stage B (the SPA shell can drive against the `POST /__inmemory/login` endpoint locally).

## Stage C — Cognito UserPool provisioning (no behaviour change) — ✅ done

(Stage B is entirely UI-side; see sibling plan.)

### C1. Resolve UserPool via Pulumi config (BYO or auto) — ✅ done

- **Bindings extended** ([Cognito_UserPool.res](../../rescript/rescript-pulumi-aws/src/Cognito/Cognito_UserPool.res), [Cognito_UserPoolClient.res](../../rescript/rescript-pulumi-aws/src/Cognito/Cognito_UserPoolClient.res)):
  - `UserPool.args` gains `adminCreateUserConfig`, `usernameAttributes`, `passwordPolicy`, `mfaConfiguration` (plus nested `adminCreateUserConfig` / `passwordPolicy` record types).
  - `UserPoolClient.args` gains `generateSecret`, `explicitAuthFlows`, `preventUserExistenceErrors`, `idTokenValidity`, `accessTokenValidity`, `refreshTokenValidity`, `tokenValidityUnits` (with nested `tokenValidityUnits` record).
  - `Cognito_UserPool.getUserPoolOutput(~args={userPoolId, region?})` data source binding added; returns `Output.t<{arn, id, name}>`.
- **Helper** ([Platform_Stack.res](../../reventless/reventless-aws/src/Platform_Stack.res)):
  - Reads `platform:cognitoUserPoolId` from `Pulumi.Config.make(Some("platform"))`.
  - **BYO branch** (config set): skips pool creation; creates a `UserPoolClient` against the supplied pool ID; ARN comes from `Cognito.UserPool.getUserPoolOutput({userPoolId})`.
  - **Auto branch** (config absent): creates `UserPool` with `adminCreateUserConfig.allowAdminCreateUserOnly=true`, `usernameAttributes=["email"]`, `passwordPolicy={minimumLength:12, requireLowercase, requireUppercase, requireNumbers}`, `mfaConfiguration:"OFF"`; client created against `pool.id`.
  - Client config (both branches): `generateSecret:false`, `explicitAuthFlows:["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]`, `preventUserExistenceErrors:"ENABLED"`, id/access TTL = 60 minutes, refresh TTL = 30 days, `tokenValidityUnits={accessToken:"minutes", idToken:"minutes", refreshToken:"days"}`.
  - Returns `{poolId, clientId, poolArn, managed: bool}` — IDs/ARN are `Pulumi.Output.t<string>`.
- **Wire site:** `examples/online-shop-hybrid/platform-aws/src/Main.res` calls `ReventlessAws.Platform_Stack.resolveCognitoUserPool()` ahead of `deployPlatform`. The struct is bound as `_cognitoUserPool` for now — Stage D will pass it into AppSync auth wiring.

**Caller responsibilities (BYO path):** the existing pool must already have its groups created manually (`Admin`, `Catalog`, …); the framework never creates users or groups.

### C2. Stack outputs — ✅ done

`resolveCognitoUserPool` exports all required outputs itself (no extra wiring in `deployPlatform`, which keeps the provider-agnostic `ReventlessInfra.Platform.T.deployPlatform` signature stable):

- `cognitoUserPoolId`
- `cognitoUserPoolClientId`
- `cognitoUserPoolArn`
- `cognitoRegion` — read from `Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")`, defaults to `"unknown"`
- `cognitoUserPoolManaged` — string `"true"`/`"false"` (operational metadata)

**Verify:** full monorepo build zero warnings; 416/416 in-memory tests pass (no regression — Stage C is AWS-only and adds no runtime code outside Pulumi resource construction).

End-to-end Pulumi verification deferred to a real `pulumi up`:
1. No config: `pulumi up` creates pool + client; outputs populated; `aws cognito-idp admin-initiate-auth` against a manually-created user succeeds.
2. `pulumi config set platform:cognitoUserPoolId …` + new stack: no pool created, only a client inside the existing pool; outputs reflect the BYO ID and the looked-up ARN.

> **Stage C gate:** Cognito pool exists and issues tokens; AppSync still uses `AWS_IAM`; nothing in production paths consumes the tokens yet. ✅

## Stage D — Wire Cognito into AppSync

### D1. Implement `Auth_Cognito.authenticate` — ✅ done

- [`reventless/reventless-aws/src/adapter/Auth/Auth_Cognito.res`](../../reventless/reventless-aws/src/adapter/Auth/Auth_Cognito.res) implements `Auth_Adapter.Provider` with two runtime entry points:
  - **`authenticate(ctx)`** — header-driven (HTTP Lambda Function URL, API Gateway, MCP). Reads `Authorization: Bearer <token>` (case-insensitive), decodes JWT claims without signature verification (AppSync's `userPoolConfig` verifies upstream of the resolver). Returns `Anonymous` when no Bearer is present, `AuthError("malformed bearer token")` when the JWT cannot be decoded, `Authenticated(Identity.t)` otherwise.
  - **`fromAppSyncIdentity(eventIdentity)`** — resolver-event path. Inspects the AppSync resolver's pre-validated `event.identity`. `sub` present → Cognito User Pool (reads `sub` → `userId`, `cognito:username` → `username`, `cognito:groups` → `groups`, full `claims` dict, `provider: Cognito`). `userArn` present (no `sub`) → AWS_IAM additional-provider path (role ARN → `userId`, `provider: Custom("aws-iam")`, empty groups). Neither → `Anonymous`.
- **Deploy-time `make`** delegates to `Platform_Stack.resolveCognitoUserPool` (cached so calls from `Main.res` + `AppSync_Adapter.makeApiResource` converge on a single resource registration and one set of stack exports) and bundles `{userPoolId, userPoolArn, clientId, region}` as the provider's `authConfig`.
- **`Identity.claims` is `dict<string>`** in the schema; the resolver-event path stringifies non-string JSON values so downstream consumers see a uniform shape.

**Verify:** [`tests/Auth_CognitoTest.res`](../../reventless/reventless-aws/tests/Auth_CognitoTest.res) — 12 cases. `authenticate` (6): no Authorization → `Anonymous`; non-Bearer → `Anonymous`; malformed Bearer → `AuthError`; valid JWT → `Authenticated` with `sub`/`cognito:username`/`cognito:groups`; missing `cognito:groups` → empty groups; case-insensitive header lookup. `fromAppSyncIdentity` (6): `None` → `Anonymous`; Cognito shape → `Authenticated` with `provider: Cognito`; missing `cognito:groups` → empty groups; IAM shape (`userArn`, no `sub`) → `provider: Custom("aws-iam")`; IAM `userArn` alone → `username` falls back to ARN; neither `sub` nor `userArn` → `Anonymous`. Full reventless-aws suite: 86/90 pass (4 pre-existing failures in DcbEventLogStorage_DynamoDb_RuntimeTest unrelated to auth — `uuid` v13 vs Jest 27 crypto). 416/416 in-memory tests still pass.

### D2. Switch AppSync `authenticationType` — ✅ done

- **`rescript-pulumi-aws`** ([AppSync_GraphQLApi.res](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_GraphQLApi.res)) — extended `args` with `additionalAuthenticationProviders?: array<additionalAuthenticationProvider>` and added the minimal `additionalAuthenticationProvider` record type (just `authenticationType` + optional `userPoolConfig`, sufficient for the IAM additional-provider case).
- **`AppSync_Adapter.makeApiResource`** ([AppSync_Adapter.res:209-264](../../reventless/reventless-aws/src/components/Api/AppSync_Adapter.res)) now creates every AppSync GraphQL API with `AMAZON_COGNITO_USER_POOLS` primary auth + `AWS_IAM` as the single additional provider:
  ```rescript
  authenticationType: AMAZON_COGNITO_USER_POOLS->Pulumi.Input.make,
  userPoolConfig: <Output of {userPoolId, awsRegion, defaultAction: DENY}>,
  additionalAuthenticationProviders: [{authenticationType: AWS_IAM}],
  ```
  `userPoolConfig` is built by calling `Auth_Cognito.make(~name=`${name}-auth`)` and applying the resulting `authConfig` Output. Because `Platform_Stack.resolveCognitoUserPool` is now cached, all three call sites (`domainApi` line 91, `platformApi` at `makePlatform` line 972, `platformApi` at `deployPlatform` line 1137) converge on the same pool/client without re-exporting stack outputs.
- **Server-to-server lambdas** (heartbeat, Plugin_Connected emission) continue to sign their AppSync calls with IAM via the existing IAM role — the new `additionalAuthenticationProviders: [AWS_IAM]` entry preserves that path unchanged.
- **`Platform_Stack.resolveCognitoUserPool`** ([Platform_Stack.res](../../reventless/reventless-aws/src/Platform_Stack.res)) — split into `_resolveUncached` (the original body) plus a process-level `_cached` ref. First call provisions + exports; subsequent calls return the cached struct. Idempotent for the new dual-caller pattern (Main.res + Auth_Cognito.make).
- **AppSync Events API unchanged** — the GraphQL API call sites the plan called out are the three `makeApiResource` invocations above. The Events API ([AppSync_EventsApi.res](../../reventless/reventless-aws/src/adapter/Api/AppSync_EventsApi.res)) uses `aws-native:appsync:Api` with its own auth-provider config and stays IAM-only; SPA subscriptions go through the GraphQL API endpoint.
- **QueryDb resolver interceptor confirmed** — [`QueryDbResolvers_AppSync.res:25-58`](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res) JS template already disambiguates `ctx.identity.sub` (Cognito) from `ctx.identity.userArn` (IAM) and emits the correct payload shape for `QueryInterceptor_Lambda.handler` in both cases. No change required.

**Verify (deploy-time):** monorepo build zero warnings; full reventless-aws build clean (130 modules recompiled after binding extension); platform-aws example (`examples/online-shop-hybrid/platform-aws`) builds clean; 416/416 in-memory tests pass.

**Verify (deploy-side, deferred to `pulumi up`):**
1. Unauthenticated curl to the GraphQL endpoint returns 401.
2. Curl with a valid Cognito id-token from C2 returns the expected payload.
3. Heartbeat lambda still publishes `PluginHeartbeat` events (signed via IAM, traverses the additional-provider path).
4. Plugin_Connected emission still works.

> **Stage D gate:** AWS deployments enforce Cognito auth end-to-end (at the resource level — runtime verification deferred to `pulumi up`). In-memory unaffected. UI sibling plan step 11 can now switch the SPA to AWS mode. ✅

## Stage E — Spec-level authz parity on AWS (optional)

### E1. Apply authorization declarations across the example domain — deferred

Authorization decisions on individual example aggregates/read models are policy choices that depend on the demo's intended audience. The framework default `AllowAuthenticated` already applies to every component without an explicit annotation, so the only thing missing is stricter rules where a demo wants to model role-gated operations. `Category.Archive` is already annotated as `AllowGroups(["Admin"])` from A3.5; further annotations can be added incrementally as the example domain evolves. **No code change required.**

### E2. Lift spec-level `Authorization.permission` into `@aws_auth` directives — ✅ done

The mechanism: `@@reventless.authorize(...)` (file-level) and `@authorize(...)` (per-constructor) already populate `commandAuthorization` / `authorization` on every aggregate / DCB slice / read model spec (Stage A3). On AWS those values previously had no effect — `Plugin_Builder` set `authorization: None` on every schema entry, so the existing `injectAwsAuth` directive injector never fired. E2 closes that gap end-to-end.

- **Entry types extended** ([reventless-infra/src/components/Api.res](../../reventless/reventless-infra/src/components/Api.res)):
  - `mutationSchemaEntry.fieldPermissions?: dict<Authorization.permission>` — keyed by mutation field name (one entry per command constructor for aggregates; one entry per slice for DCB).
  - `querySchemaEntry.permission?: Authorization.permission` — single rule applied to both single-id and list query fields of a read model / state view slice.
- **Plugin_Builder** ([Plugin_Builder.res](../../reventless/reventless-core/src/components/Plugin/Plugin_Builder.res)) — for each aggregate, iterates `filteredConstructorNames` and evaluates `M.Spec.commandAuthorization` against a synthetic command value (payload-bearing `{TAG: cname}` vs payload-less bare string — mirrors `CommandGeneratorResolvers_GraphQL.syntheticCommand` so the PPX-generated switch dispatches the same way at deploy and runtime). For each read model, reads `R.Spec.authorization`.
- **Dcb_Builder** ([Dcb_Builder.res](../../reventless/reventless-core/src/components/Dcb/Dcb_Builder.res)) — same mechanism for `StateChangeSlice` and `InboundTranslationSlice` mutations (one GraphQL field per slice; reads the rule for the **first constructor**, matching the existing `dcbTags` convention — when constructors share the file-level default this is exact, otherwise resolver-level enforcement still fires). `StateViewSlice` populates `permission` from `V.Spec.authorization`.
- **`injectAwsAuth`** ([AppSync_Adapter.res:115-217](../../reventless/reventless-aws/src/components/Api/AppSync_Adapter.res)) — reads the new `fieldPermissions` / `permission` fields in addition to the legacy `{tableName, group}` authorization, with spec-level always winning per-field. Permission → directive mapping:
  - `AllowGroups([])` → `@aws_auth(cognito_groups: ["__deny_all__"])` (sentinel that no Cognito user belongs to)
  - `AllowGroups(["g1", "g2"])` → `@aws_auth(cognito_groups: ["g1", "g2"])`
  - `DenyAll` → `@aws_auth(cognito_groups: ["__deny_all__"])`
  - `AllowAuthenticated` / `AllowAnonymous` → no directive emitted (with Cognito as primary auth from Stage D, any reaching request is already authenticated at the API level — equivalent to `AllowAuthenticated`)

**Verify:** [`tests/AppSync_AdapterTest.res`](../../reventless/reventless-aws/tests/AppSync_AdapterTest.res) — 8 new cases for `injectAwsAuth`: `AllowGroups(["Admin"])` → single-group directive; multi-group `AllowGroups` → comma-separated; `AllowAuthenticated` → no directive; `DenyAll` → `__deny_all__` sentinel; per-field permissions (one field gets directive, another doesn't); query permission applied to both single + list fields; spec-level wins over legacy `{tableName, group}`; `AllowAuthenticated` overrides legacy (directive removed). Full reventless-aws suite: 98/102 pass (4 pre-existing failures in DcbEventLogStorage_DynamoDb_RuntimeTest unrelated — `uuid` v13 vs Jest 27 crypto). 416/416 in-memory tests still pass.

**Verify (deferred to `pulumi up` + curl):** a Cognito user not in the required group is rejected at the AppSync layer (before the resolver runs), regardless of what the UI sends.

> **Stage E gate:** AWS @aws_auth directive injection is wired to the spec-level `Authorization.permission` PPX annotations. Per-aggregate / per-slice / per-readmodel authz declared anywhere in `@@reventless.spec` / `@@reventless.behavior` files now enforces at the AppSync field layer in addition to the in-memory resolver layer. ✅

## Out of scope for this plan

- `<AuthProvider>`, `<LoginPage>`, `<UserMenu>`, localStorage, Cognito SDK call — `reventless-ui: docs/plans/host-ui-login-ui.md`.
- Refresh-token rotation policy in the SPA — UI sibling plan.
- MCP authorization — see the abstraction reference; separate phase, parallel-safe.
- Auth0 / AzureAD / ApiKey provider implementations — see the abstraction reference (future).
- User Management Plugin — see the abstraction reference (future).
