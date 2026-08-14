# Plan: group authorization is not enforced on the AWS path

**Status. FIXED AND VERIFIED 2026-08-14** (`13926388c`, deployed to alpha). The
gate was confirmed open by observation, fixed, redeployed, and confirmed closed
by the same probe — before and after, same command, same two callers. §8 records
both halves. This plan supersedes
[appsync-refusal-vocabulary.md](done/appsync-refusal-vocabulary.md), whose step 0
produced the observation and whose step 1 required stopping if it came out this
way. It did.

**Severity.** Every `@authorize(AllowGroups([...]))` gate in the framework is
inert once deployed to AppSync. Any caller who can obtain *any* Cognito token
for the pool — including a self-registered user in no groups at all — can read
and write every group-gated field. `DenyAll` is inert on the same mechanism.

## §1 — What was observed

Against the alpha `online-shop-hybrid` deployment in `eu-west-1`, with a
throwaway Cognito user in **no groups** (created for the probe, deleted after):

| # | Caller | Field | Result |
| --- | --- | --- | --- |
| 1 | no token | `Platform_ComponentDefinitions` | **HTTP 401** `UnauthorizedException` |
| 2 | malformed token | `Platform_ComponentDefinitions` | **HTTP 401** `UnauthorizedException` |
| 3 | valid token, **in** `Admin` | `Platform_ComponentDefinitions` | HTTP 200, data |
| 4 | valid token, **no groups** | `Platform_ComponentDefinitions` | **HTTP 200, full data** |

Row 4 is the finding. It reproduced on every group-gated field probed, across
both merged APIs:

```
# PlatformMergedApi (klgg3ye3pbch5gdjax3t7ufmwm) — @aws_auth(cognito_groups: ["Admin"])
Platform_ComponentDefinitions → {"data":{"Platform_ComponentDefinitions":[
  {"pluginId":"Platform"},{"pluginId":"Ordering"},{"pluginId":"Catalog"}]}}
Platform_Plugins(first:3)     → {"data":{"Platform_Plugins":{"edges":[
  {"node":{"id":"Ordering","name":"Ordering","status":"Connected"}}, …]}}}
Platform_UIFragments          → {"data":{"Platform_UIFragments":[]}}

# DomainMergedApi (25ndeodnyvf5fcx2vzxyt5epp4) — @aws_auth(cognito_groups: ["Admin","Fulfilment"])
Ordering_Customers(first:2)   → {"data":{"Ordering_Customers":{"edges":[
  {"node":{"id":"cust-03"}},{"node":{"id":"cust-04"}}]}}}
Catalog_ProductDemands(first:2) → {"data":{"Catalog_ProductDemands":{"edges":[
  {"node":{"id":"prd-012"}},{"node":{"id":"prd-011"}}]}}}
```

**Writes are equally open.** An `Admin`/`Fulfilment`-gated mutation, called by
the no-group user with a deliberately nonexistent id, reached the command
handler and came back with a *business* rejection rather than an authorization
refusal:

```
mutation { Ordering_ShipOrder(orderId: "probe-nonexistent-zzz-9999") { … } }
→ {"data":{"Ordering_ShipOrder":{"__typename":"CommandRejected",
   "errorCode":"OrderNotFound","errorDetail":null}}}
```

`OrderNotFound` is the aggregate speaking. The gate never ran.

Verbatim body for rows 1–2:

```json
{ "errors" : [ { "errorType" : "UnauthorizedException",
                 "message" : "Valid authorization header not provided." } ] }
```

## §2 — Why

`@aws_auth` is the **single-mode** directive. AppSync honours it only when
`AMAZON_COGNITO_USER_POOLS` is the sole authorization mode. Both APIs configure
Cognito as primary **plus `AWS_IAM` as an additional provider**, which is what
`systemCallable` deploy-time callers need. On such an API the service ignores
`@aws_auth` rather than rejecting the schema — deploys succeed, the directive
appears in the deployed SDL, and it does nothing.

What is then left is `userPoolConfig.defaultAction`, which both APIs set to
**`ALLOW`** — every authenticated Cognito user may reach every field carrying no
*effective* directive. That is the open door.

The compilation path (`AppSync_Adapter.res:186-217`):

| Spec | Emitted | Enforced? |
| --- | --- | --- |
| `AllowGroups([g…])` | `@aws_auth(cognito_groups: [g…])` | **no** |
| `AllowGroups([])`, `DenyAll` | `@aws_auth(cognito_groups: ["__deny_all__"])` | **no** |
| `AllowAuthenticated` / `AllowAnonymous` | no directive | n/a (open by design) |
| `systemCallable` fields | `@aws_cognito_user_pools(cognito_groups: […]) @aws_iam` | **yes** |

The last row matters twice: it is the only form that works, and it is already
implemented in this repo as `_formatDualAuthDirective`
(`AppSync_Adapter.res:226-234`). The fix is to route the other rows through it
rather than to invent anything.

The `DenyAll` row is the sharpest statement of the bug: a field an author marked
*nobody may call this* is callable by anyone with a token. No `DenyAll` field is
deployed in the examples today, so this is latent rather than live — but it is
the same mechanism, and it will not announce itself when someone first uses it.

### The belief that hid it

Two comments in the tree assert the opposite, and one of them is load-bearing:

- `Auth_ActiveRoleTrigger_Ops.res:8-14` — "`@authorize(AllowGroups([...]))`
  compiles to `@aws_auth`, which AppSync evaluates against `cognito:groups`
  **before any of our code executes**". This is the stated reason the pre-token
  -generation trigger exists at all. The premise is false on a multi-auth API,
  so the trigger narrows a claim that nothing subsequently reads for
  authorization.
- `AppSync_Adapter.res:198-199` states, correctly, that "`@aws_auth(...)` is the
  single-mode directive form and **does not admit IAM on a multi-auth API**" —
  the incompatibility was seen for the *IAM* arm and the conclusion was not
  carried to the *Cognito* arm.

## §3 — Blast radius

- **Both example platforms**, every group-gated field: 18 on the platform/admin
  surface, 14 on the domain surface, in the hybrid stack alone.
- **Every Reventless AWS deployment**, unconditionally. The multi-auth
  configuration is not opt-in: `AppSync_Adapter.res:277` — "Unconditional — the
  API always configures AWS_IAM as an additional provider" — and `:528-539`
  provisions it on every API, for the server-to-server lambdas (heartbeat,
  `Plugin_Connected` emission) that need it regardless. So *any* deployment
  using `@authorize(AllowGroups(...))` is affected from birth. No example spec
  in the tree even uses `@@reventless.systemCallable`, and alpha is exposed
  anyway.
- **`systemCallable` fields are the exception that works.** They are the only
  fields emitting `@aws_cognito_user_pools(cognito_groups: [...])`, so they are
  the only ones whose Cognito group gating AppSync actually enforces. The
  opt-in that exists to *widen* access is incidentally the only correct gate —
  which is why the fix is to make every field emit what they already do.
- **`Auth_ActiveRole`** — role narrowing is currently decorative on this path.
- **Not affected:** the local adapter, which enforces in its own code
  (`Auth_GraphqlContext.res`) and was the subject of `69c4fabc5`. The two
  adapters do not merely word refusals differently; one refuses and one does
  not.

## §4 — Fix

**Primary — emit the enforced form for group gates.** Replace
`_formatGroupsDirective`'s `@aws_auth(...)` output with
`@aws_cognito_user_pools(cognito_groups: [...])`, adding `@aws_iam` only where
`systemCallable` already asks for it.

The change had two emission sites, not one: `AppSync_Adapter._formatGroupsDirective`
(mutations + queries, from schema entries) and `AppSync_SdlDecorate.injectAwsAuthAll`
(the admin base — mutations, queries **and subscriptions**, which inlined the
directive rather than calling a helper). Both now route through a single
`AppSync_SdlDecorate.formatCognitoGroupsDirective`, so they cannot drift again.
Subscriptions keep the Cognito gate and stay IAM-free — a subscription is a read.

**The goldens do not capture this.** `reventless/spec/schema/*.graphql` record
contract shape (types and fields) and contain zero auth directives, so
`check:graphql` stays green through both the bug and the fix. Do not treat it as
evidence either way — the guard is the unit assertion plus the deployed probe.

**Defence in depth — set `defaultAction: DENY`.** With `ALLOW`, any field whose
directive is missing or malformed fails open. `DENY` makes the same class of
future mistake fail closed. This needs every intentionally-open field to carry
an explicit directive, so it is the larger change of the two; do it second, and
verify against the goldens.

**Do not rely on the runtime layer to cover this.** `Plugin_Structure.res:303-318`
resolves `AllowGroups` for the indexed-access path, but the observation above
shows a gated mutation reaching its handler, so it is not a backstop today.
Establish what it does and does not cover before assuming any of it.

## §5 — Steps

**Done (2026-08-14), shipped in `13926388c` and deployed to alpha:**

- ✅ **2. Both emission sites now emit `@aws_cognito_user_pools(...)`**, routed
  through one canonical `AppSync_SdlDecorate.formatCognitoGroupsDirective`.
  Rendering the real admin base confirms the shapes:
  ```graphql
  Platform_Plugin(id: ID!): Platform_Plugin @aws_cognito_user_pools(cognito_groups: ["Admin"])
  Platform_Plugin_Deactivate(...): CommandResult!
      @aws_cognito_user_pools(cognito_groups: ["Admin"])
  Platform_Plugin_Activate(...): CommandResult!            # systemCallable
      @aws_cognito_user_pools(cognito_groups: ["Admin"]) @aws_iam
  onUIFragmentChange: UIFragmentChangeEvent                 # never IAM
      @aws_cognito_user_pools(cognito_groups: ["Admin"])
  ```
- ✅ **3. Goldens** — verified they do not capture directives at all (see §4);
  `check:graphql` green, unchanged, and not evidence.
- ✅ **5. Comments corrected** — `Auth_ActiveRoleTrigger_Ops.res` (its premise is
  true again now that the directive is enforced, and says so),
  `AppSync_Adapter.res`, `docs/guides/appsync-iam-system-caller.md`, and
  `docs/analysis/authentication-authorization.md` (dated correction; the doc
  predates the fix and several statements assumed the old form).
- ✅ **Tests** — assertions moved to the enforced form; the three
  `not_->toContain("@aws_auth")` "no directive" checks were rewritten, since
  after the fix they would have passed vacuously. Added a regression test that
  the single-mode form appears on **no** field. Full suite green (335 suites /
  3193 tests).
- ✅ **Probe kept** as `scripts/probe-appsync-group-gate.mjs` — the four rows,
  reusable against any deployment. It reports INCONCLUSIVE (exit 1) rather than
  "enforced" when the no-group caller is not supplied: the unauthenticated rows
  passed throughout the whole outage and prove nothing about the gate.

- ✅ **1. Deployed and re-probed** — see §8.

**Remaining, as separate work:**

2. **`defaultAction: DENY`** — the change that makes the *class* of mistake
   impossible rather than this one instance of it. Done in two phases, because
   flipping it blind would have taken the whole app down.

   **Why phased.** Under `DENY`, "no directive" stops meaning *open* and starts
   meaning *refused* — for types as well as fields, since response shaping walks
   `…Connection` → `…Edge` → node → nested state types and dies one level in on
   an undirectived type. Measured against the deployed alpha SDL before touching
   anything:

   | Surface | Carried a directive | Total |
   | --- | --- | --- |
   | Domain `Query` | 4 | 35 |
   | Domain `Mutation` | 10 | 22 |
   | Domain `Subscription` | **0** | 22 |
   | Domain types | 4 | 61 |
   | Platform types | 4 | 34 |

   Flipping first would have refused roughly 65 fields and 87 types — nearly
   the entire application — for every caller.

   - ✅ **Phase 1 — stamp everything explicitly, default still `ALLOW`.** Every
     field with no group restriction (`AllowAuthenticated`, `AllowAnonymous`, or
     no permission at all) now emits the group-less
     `@aws_cognito_user_pools`; every object type does too, via
     `stampAllTypesCognito` on the assembled SDL (after `stampSharedIamTypes`,
     so shared traversal types keep their `@aws_iam` arm). Subscriptions were
     the worst gap — `injectAwsAuth` re-encoded them untouched, so all 22 domain
     subscriptions reached the deployed SDL with no directive; they now take the
     Cognito arm, inheriting the groups of a like-named gated mutation, and are
     never IAM-marked.

     **This phase is a semantic no-op under `ALLOW`** — that is the point. It
     makes a miss harmless and observable, instead of an outage.

   - ⬜ **Phase 2 — flip the default.** Only once the *deployed* SDL shows 100%
     coverage. `defaultAction: ALLOW` appears in three places
     (`Platform.res:338`, `AppSync_Adapter.res:518`,
     `AppSync_MergedApi.res:103`) and all three must move together.

     Gate on the deployed SDL, not on local rendering:
     ```
     aws appsync get-introspection-schema --api-id <id> --format SDL \
       --include-directives /dev/stdout | grep -c '^type .*[^@]*{'   # undirectived types must be 0
     ```
     Then re-probe **both** directions — the unentitled caller still refused,
     and an ordinary authenticated caller still able to reach the open fields.
     The second half matters more here: phase 2's failure mode is refusing
     everybody, which the group probe alone would score as a pass.
3. **Revisit the refusal-vocabulary question**
   ([done/appsync-refusal-vocabulary.md](done/appsync-refusal-vocabulary.md)).
   Its §2 table can now be written from observation: the AWS path answers an
   unentitled caller with HTTP 200 + `errorType: "Unauthorized"`, and an
   unidentified one with HTTP 401 — which is exactly what it predicted, and is
   still a different shape from the local adapter's `extensions.code`.

## §6 — Acceptance

- ✅ A Cognito user in no groups is refused by every group-gated field on a
  deployed API, with the refusal captured verbatim here (§8).
- ✅ A user holding the required group still succeeds on the same fields (§8).
- ⬜ `DenyAll` and `AllowGroups([])` are observed to refuse everyone. **Not
  observed** — no `DenyAll` field is deployed in the examples, so there was
  nothing to point a caller at. It rides the same `_formatGroupsDirective` path
  that is now verified, but that is inference, not observation. Worth an
  explicit probe the first time a `DenyAll` field ships.
- ➖ The GraphQL goldens reflect the new directive form. **Not applicable** —
  the goldens capture contract shape and contain no auth directives at all
  (§4). Verified instead against the deployed SDL: 0 `@aws_auth`, 18
  `@aws_cognito_user_pools`.
- ✅ No comment in the tree still asserts that `@aws_auth` is enforced here.

## §7 — Reproduction

The probe is four requests against a deployed API and needs two Cognito users —
one in the gated group, one in none. The users created for the original
observation (`refusal-probe-admin`, `refusal-probe-plain`) were deleted
immediately afterwards; the `examples-dev` pool
(`eu-west-1_CQTwafSeX`) is back to its six standing users. Recreate throwaways
rather than reusing `admin`/`shopper`, whose credentials CI depends on.

## §8 — Verification (2026-08-14)

Same command, same two throwaway callers, against the alpha merged Platform API
— once before the deploy and once after. Users created for the probe and deleted
immediately after; the `examples-dev` pool is back to its six standing users.

```
node scripts/probe-appsync-group-gate.mjs \
  --endpoint https://lhe7fojedjgqhhdtvxgbzt2xyi.appsync-api.eu-west-1.amazonaws.com/graphql \
  --client-id <host-ui client> --region eu-west-1 \
  --query 'query { Platform_ComponentDefinitions { pluginId } }' \
  --in-group-user <in Admin> --no-group-user <in no groups>
```

| Caller | Before (`f698ff8a4`) | After (`13926388c`) |
| --- | --- | --- |
| no token | 401 `UnauthorizedException` | 401 `UnauthorizedException` |
| malformed token | 401 `UnauthorizedException` | 401 `UnauthorizedException` |
| valid token, in `Admin` | 200, data | 200, data |
| valid token, **no groups** | **200, full data** | **200, `errorType: "Unauthorized"`, `data: null`** |

Probe exit code went 1 → 0.

The refusal body the unentitled caller now receives:

```json
{"data":null,"errors":[{"path":["Platform_ComponentDefinitions"],"data":null,
  "errorType":"Unauthorized","errorInfo":null,
  "locations":[{"line":1,"column":9,"sourceName":null}],
  "message":"Not Authorized to access Platform_ComponentDefinitions on type Query"}]}
```

**Deployed SDL** — the merged Platform API now carries `@aws_auth` on **0**
fields and `@aws_cognito_user_pools(cognito_groups: [...])` on all **18**.

**Every field found open in §1 is now closed**, on both APIs, for the no-group
caller:

| Field | Before | After |
| --- | --- | --- |
| `Platform_ComponentDefinitions` | data | `Unauthorized` |
| `Platform_Plugins` | data | `Unauthorized` |
| `Ordering_Customers` | data | `Unauthorized` |
| `Catalog_ProductDemands` | data | `Unauthorized` |
| `Ordering_ShipOrder` (mutation) | reached handler → `OrderNotFound` | `Unauthorized` |

The mutation row is the sharpest: it previously got past the gate and into the
command handler, and is now refused at the gate.

**No gate admits fewer callers than intended.** The `Admin` caller still reads
`Ordering_Customers`, `Catalog_ProductDemands` and `Platform_Plugins`. The
deploy-time IAM system caller is exercised by the deploy itself, which succeeded
— `systemCallable` fields kept their `@aws_iam` arm.

CI, Repo hygiene, Release and Deploy Online Shop Hybrid all succeeded on
`627ec0825`.
