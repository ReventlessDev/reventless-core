# Plan: the AppSync path says which refusal it gave

**Status. CLOSED 2026-08-14 — §6.1 answered badly, exactly as feared.** Step 0
was run against the deployed alpha API. `@aws_auth` is **not enforced** on these
multi-auth APIs: a Cognito user in no groups read every admin-gated field and
executed a group-gated mutation. Per step 1, this plan is closed in favour of
[appsync-group-authorization-unenforced.md](../appsync-group-authorization-unenforced.md),
which carries the captured bodies and the fix.

**The §2 table below is disproven, not merely unverified.** Its middle row
predicted that an identified-but-unentitled caller meets a field error; the
observed behaviour is that the resolver *runs*. Nothing in §4's options survives
that: there is no refusal vocabulary to reconcile until there is a refusal.

What did survive: §1 (the local adapter's behaviour, unchanged), §3's diagnosis
that the two adapters are unreconciled — now understood to be a far deeper
disagreement than wording — and the three asymmetries in §3, which remain
accurate about the AWS path's shape. Reopen this plan (`git mv` back per repo
convention) once group gating is actually enforced; the vocabulary question is
then worth asking from observation rather than from assumption.

---

**Original status.** Design only — nothing built. The local adapter gained the
distinction on 2026-08-14 (`69c4fabc5`): a caller it identified who lacks the
required group is refused with `FORBIDDEN`, and `UNAUTHORIZED` is left to the
caller it could not identify. The AWS path still has one vocabulary for both,
and it is not the same vocabulary.

Two of this plan's premises are **unverified against a live API** and are listed
as step 0 rather than assumed. One of them (§6.1) is a question about whether an
existing gate is enforced at all, and it should be answered before anything here
is built — if it answers badly, it outranks this plan entirely.

## §1 — What the local path settled

An admin-gated resolver has two ways to refuse and they ask for opposite things.
A caller whose credentials did not verify should present new ones; a caller who
is simply not entitled will meet the same answer however many times they
authenticate. Answering both with one code leaves every client to guess, and the
guess that fits an expired token — discard the session, ask them to sign in —
ends a working session for the caller who was only ever unentitled.

The local adapter now separates them at the point where the information still
exists (`reventless/local/src/adapter/Auth/Auth_GraphqlContext.res`):
`buildAuthContext` carries the authentication outcome beside the identity,
because `identityFromAuthResult` maps both `Anonymous` and `AuthError` onto the
anonymous identity and by the time a group check runs the distinction is gone.

| Caller | Local adapter |
| --- | --- |
| Identified, holds the group | resolver runs |
| Identified, lacks the group | HTTP 200 · `extensions.code = FORBIDDEN` |
| Credentials did not verify | HTTP 200 · `extensions.code = UNAUTHORIZED` |

## §2 — The finding that changes the shape

The obvious reading of "fix the AWS side" is: move the gate out of the directive
and into the resolver, so our own code can choose the code. That reading is
wrong, or at least premature, because **AppSync already draws the distinction —
in a different vocabulary, at a different layer.**

The API is `AMAZON_COGNITO_USER_POOLS` primary with `AWS_IAM` additional
(`reventless/aws/src/components/Api/AppSync_Adapter.res:462`, `:531-549`). A
request whose JWT does not verify is rejected by the service before the schema
is reached — the request never becomes a GraphQL execution at all. A request
whose JWT does verify, against a field carrying
`@aws_auth(cognito_groups: ["Admin"])`, executes and is refused per-field.

So the split is already there. It is expressed as **transport status versus
field error**, where the local path expresses it as **two extensions codes**:

| Caller | AWS path (expected — see §6.2) | **Observed 2026-08-14** |
| --- | --- | --- |
| Identified, holds the group | resolver runs | ✅ resolver runs |
| Identified, lacks the group | HTTP 200 · field error · `errorType: "Unauthorized"` | ❌ **resolver runs — no refusal at all** |
| Credentials did not verify | HTTP 401 · no field error | ✅ HTTP 401 `UnauthorizedException` |

> **The middle row is wrong.** The paragraph below it — "a field-level
> authorization refusal can *only* reach a caller the service already
> authenticated" — is true but vacuous: on this configuration there is no
> field-level refusal to reach anyone. See
> [appsync-group-authorization-unenforced.md](../appsync-group-authorization-unenforced.md).

Note what that second row means: on this path, a field-level authorization
refusal can *only* reach a caller the service already authenticated. The
unentitled case and the unidentified case are not merely distinguishable — they
arrive at different layers and cannot be confused.

## §3 — What is actually missing

Not the distinction. The **conformance**.

Two adapters of one framework answer the same refusal in two unrelated shapes,
and nothing in the framework says so. A client written against one is wrong
against the other, and wrong quietly: it reads for a key that is never present,
finds nothing, and proceeds as though nothing was refused.

That is the same class of gap `Auth_ActiveRole.res` closed for claim names,
where the fix was a shared table both paths are held to rather than each path
being asked to imitate the other. The problem here is not that AppSync is
impolite; it is that a caller cannot write one piece of code against "a
Reventless platform".

Three further asymmetries the map turned up, which bound what is even possible:

- **`extensions` is not reachable from an AppSync resolver.** Nothing anywhere
  on the AWS path sets it. The runtime offers `util.error(message, errorType)`
  (`rescript/pulumi-aws/src/AppSync/AppSync_ResolverRuntime.res:95`) and
  `util.unauthorized()` (`:99`); `errorType` is the only structured slot, and
  the sole literal use in the tree is unrelated
  (`AppSync_Resolver_Functions.res:548`). **Matching the local path's exact
  shape is therefore not on the table.** Conformance has to be a mapping, not
  an equality.
- **The admin resolvers do not receive the caller.** Both platform Lambda
  templates send `payload: {}`
  (`Platform_ComponentDefinitions_Lambda.res:16-25`, `:29-38`;
  `Platform_UIFragments_Lambda.res:11-20`). Their *only* authorization is the
  schema directive. Any resolver-level decision would first require forwarding
  identity, which five other call sites already do by hand with a duplicated
  inline block.
- **The directive is blanket.** `injectAwsAuthAll`
  (`AppSync_SdlDecorate.res:90-119`) stamps every mutation, query and
  subscription of the admin base with one group, and `Platform.res:274-280`
  passes `~group="Admin"` with no exceptions. There is no per-field seam here
  to make an exception in.

## §4 — Options

**A. Publish the mapping; change no infrastructure.** State, in one place both
adapters are held to, what each refusal looks like per adapter — the table in
§2 — and provide it as data rather than prose so a client can be written
against the framework instead of against a deployment. Costs nothing at
runtime, risks nothing, and closes §3's actual gap.

**B. Move the admin gate into the resolvers.** Drop `@aws_auth` from the
platform fields, forward identity into the platform Lambdas, and have them
refuse with `util.error(msg, "Forbidden")`. Yields a per-adapter vocabulary that
differs only by slot name.

The cost is not implementation, it is the trade: **a declarative deny the
service enforces becomes an imperative deny our code enforces**, across every
field of the admin surface, where the failure mode of an omission is an open
admin query rather than a broken one. `injectAwsAuthAll` is blanket precisely
so that no field can be forgotten; option B replaces that property with a
promise. Against that, it buys a distinction the caller can already make from
the status code.

**C. Do nothing.** Defensible only while every client is written against one
adapter, and this repo cannot know that.

**Recommendation: A.** B is not ruled out forever, but it should not be done
*for this reason* — the information it produces is already obtainable, and it
pays for a nicer shape with a weaker guarantee. If B is ever built it should be
driven by something that genuinely needs resolver-level authorization on those
fields (per-field permissions, tenant scoping, an audit trail of refusals), with
the vocabulary as a side benefit.

## §5 — What this is not

**Not a change to who may call what.** Every gate stays exactly where it is and
admits exactly the same callers. This is about the framework being able to say
which refusal it gave.

**Not a fix for a caller with no surfaces.** A caller outside the admin group
still cannot discover through the admin queries, by design; baked manifests are
the answer to that and are unaffected here. The refusal being legible does not
make it not a refusal.

**Not a claim that the AWS path is currently wrong.** As far as this plan can
tell without a deployment, AppSync's behaviour is correct and complete. What is
missing is on our side: nothing states the correspondence, so nothing can be
written against it.

## §6 — Hazards, both to answer before building

### 6.1 — Is `@aws_auth` honoured on a multi-auth API at all? 🚨 **ANSWERED: NO**

> **Observed 2026-08-14.** It is **ignored**. The third outcome below is the one
> that happened: the admin surface is gated by nothing on the AWS path. A
> throwaway Cognito user in no groups received the full payload of every
> admin-gated query (HTTP 200), and a group-gated mutation reached its command
> handler. The security finding, the captured bodies and the fix are in
> [appsync-group-authorization-unenforced.md](../appsync-group-authorization-unenforced.md).
> Everything below this box is the original reasoning, kept as written.

`@aws_auth` is the **single-mode** directive. The file's own comment
(`AppSync_SdlDecorate.res:84-89`, restated at `AppSync_Adapter.res:193-206`)
says a multi-auth API must spell both arms explicitly as
`@aws_cognito_user_pools(...) @aws_iam`, which is exactly what
`formatDualAuthDirective` exists to emit — and it is emitted **only** for fields
named in `iamFieldNames`.

`Platform.res:274-280` passes **no** `iamFieldNames`. So every admin field
carries the single-mode directive on an API that is configured multi-mode
(Cognito + IAM).

Three outcomes are possible and only a deployed API can say which: the service
rejects the schema (it does not — deploys succeed), honours the directive
anyway, or **ignores it**. The third would mean the admin surface is gated by
nothing on the AWS path, which is a security finding that outranks everything
else in this file. Answer it first, and answer it by observation.

### 6.2 — The §2 table is expected behaviour, not observed **— RESOLVED: one row was wrong**

Both AWS rows are reasoned from how the service is configured, not from a
captured response. The whole plan rests on them. Capture real bodies — status
line and full JSON — for each row before writing any mapping down.

> **Observed 2026-08-14.** The caution was warranted. The 401 row held; the
> unentitled row did not. Recorded inline in the §2 table above, with verbatim
> bodies in
> [appsync-group-authorization-unenforced.md](../appsync-group-authorization-unenforced.md) §1.
> This is the case for step 0 existing at all: the plan would otherwise have
> built a mapping onto a refusal that never happens.

## §7 — Steps

**0. Observe.** Against a deployed API, with a Cognito user in `Admin` and one
outside it, capture the full response for an admin query in each of: valid token
with the group, valid token without it, malformed token, absent token. Record
HTTP status and verbatim body. This settles §6.1 and §6.2 together, and is the
only step that cannot be done from a checkout.

**1. Stop if 6.1 answers badly.** If the directive is not enforced, close this
plan and open one for that.

**2. Write the correspondence down as data**, beside the claim-name table in
`reventless/core/src/adapter/Auth/Auth_ActiveRole.res` or in a sibling module —
the two are the same kind of artifact, a fact both adapters are held to. Shape
it so a client can ask "was this refusal about entitlement?" and get an answer
per adapter, rather than each client re-deriving it.

**3. Correct the comments that assert the wrong shape.** At least
`GraphQLResponse`-style consumers have been written believing AppSync sends
`extensions.code` — the conformance table is only half the fix if the prose
around it still says otherwise. Grep both paths for claims about what AppSync
returns and reconcile them against step 0's capture.

**4. Cover it.** The local path's refusals are asserted in
`reventless/local/tests/adapter/RequireGroupRefusalTest.res`. The AWS rows
cannot be asserted without a deployment, so assert the *table* — that the
mapping names both adapters, and that the entitlement row is distinguishable
from the identity row in each.

## §8 — Acceptance

- A deployed AppSync admin query has been observed refusing all four callers of
  step 0, and the captured bodies are recorded in this file.
- §6.1 is answered in writing. If the directive is unenforced, this plan is
  closed in favour of that finding.
- The correspondence is expressed as data both adapters are held to, not as
  prose in one adapter's comments.
- A client can determine "entitlement, not identity" for a refusal from either
  adapter without knowing which adapter it is talking to.
- No gate admits a caller it did not admit before. Nothing in §7 changes the
  set of permitted callers, and a diff that does has exceeded this plan.
