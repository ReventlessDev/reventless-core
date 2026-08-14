# Plan: group authorization is not enforced on the AWS path

**Status.** Finding confirmed by observation against the deployed alpha API on
2026-08-14. Not yet fixed. This plan supersedes
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

**Done (2026-08-14), not yet deployed:**

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

**Remaining — needs a deploy, which is user-triggered:**

1. **Deploy and re-probe all four rows** against the redeployed alpha stack:
   ```
   node scripts/probe-appsync-group-gate.mjs \
     --endpoint <merged api url> --client-id <cognito app client> \
     --query 'query { Platform_ComponentDefinitions { pluginId } }' \
     --in-group-user … --in-group-pass … --no-group-user … --no-group-pass …
   ```
   Record the bodies here. Until this runs, the fix is reasoned, not observed —
   the same standard that closed the predecessor plan.
2. **Then** consider `defaultAction: DENY` as a separate change.
3. **Only after the above**, revisit the refusal-vocabulary question. Its §2
   table was reasoned from the assumption that AppSync refuses the unentitled
   caller; once that is actually true, the table can be written from observation.

## §6 — Acceptance

- A Cognito user in no groups is refused by every group-gated field on a
  deployed API, with the refusal captured verbatim here.
- A user holding the required group still succeeds on the same fields (no gate
  admits fewer callers than intended, and none admits more).
- `DenyAll` and `AllowGroups([])` are observed to refuse everyone.
- The GraphQL goldens reflect the new directive form.
- No comment in the tree still asserts that `@aws_auth` is enforced here.

## §7 — Reproduction

The probe is four requests against a deployed API and needs two Cognito users —
one in the gated group, one in none. The users created for the original
observation (`refusal-probe-admin`, `refusal-probe-plain`) were deleted
immediately afterwards; the `examples-dev` pool
(`eu-west-1_CQTwafSeX`) is back to its six standing users. Recreate throwaways
rather than reusing `admin`/`shopper`, whose credentials CI depends on.
