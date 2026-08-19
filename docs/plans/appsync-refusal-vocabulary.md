# Plan: the AppSync path says which refusal it gave

**Status. REOPENED 2026-08-14 — the premise now holds, and §2 is confirmed.**

This plan was closed the same day it was written: step 0 found that `@aws_auth`
was not enforced at all, so there was no refusal to give a vocabulary to. That
was fixed and deployed (`13926388c`, see
[appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md)),
and the four rows were re-observed against the deployed API.

**§2's table was right.** The middle row — the one this plan could not verify
and that was briefly marked disproven while the gate was open — is exactly what
the deployed API now does:

```json
{"data":null,"errors":[{"path":["Platform_ComponentDefinitions"],"data":null,
  "errorType":"Unauthorized","errorInfo":null,
  "locations":[{"line":1,"column":9,"sourceName":null}],
  "message":"Not Authorized to access Platform_ComponentDefinitions on type Query"}]}
```

So the question this plan asks is live again, and now rests on observation
rather than inference: **the two adapters do give the same refusal two
unrelated shapes.** The AWS path says HTTP 200 + `errorType: "Unauthorized"`;
the local path says HTTP 200 + `extensions.code = FORBIDDEN`. A client cannot
read one key and work against both.

§4's recommendation (option A — publish the mapping as data, change no
infrastructure) stands, and is now cheap: every cell of the table is observed.

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
`@aws_cognito_user_pools(cognito_groups: ["Admin"])`, executes and is refused
per-field. (This plan originally wrote that directive as `@aws_auth(...)`, which
is precisely the bug §6.1 uncovered — that form gates nothing here.)

So the split is already there. It is expressed as **transport status versus
field error**, where the local path expresses it as **two extensions codes**:

| Caller | AWS path — **observed 2026-08-14, post-fix** |
| --- | --- |
| Identified, holds the group | resolver runs · HTTP 200 · data |
| Identified, lacks the group | HTTP 200 · `errors[].errorType: "Unauthorized"` · `data: null` |
| Credentials did not verify | HTTP 401 · `x-amzn-errortype: UnauthorizedException` · no field error |

> Every row above is a captured response, not a prediction. The refusal bodies
> are recorded in
> [appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md) §8.
>
> **Historical note.** Between this plan being written and the fix landing, the
> middle row did not happen at all — the gate was inert and the resolver simply
> ran for everyone. That is why this plan was briefly closed. The row was right
> about what AppSync does *when the directive is the enforced form*; it was
> wrong only in assuming the adapter emitted that form.

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

### 6.1 — Is `@aws_auth` honoured on a multi-auth API at all? 🚨 **ANSWERED: NO — and fixed**

> **Observed 2026-08-14.** It is **ignored**. The third outcome below is the one
> that happened: the admin surface was gated by nothing on the AWS path. A
> throwaway Cognito user in no groups received the full payload of every
> admin-gated query (HTTP 200), and a group-gated mutation reached its command
> handler. The security finding, the captured bodies and the fix are in
> [appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md).
>
> **Resolved in `13926388c`**, deployed and re-probed: the adapter now emits
> `@aws_cognito_user_pools(cognito_groups: [...])` everywhere, and the same
> caller is refused. This hazard is closed; it is kept here because it is the
> reason the plan's own §2 could not be trusted until it was answered.
>
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
> [appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md) §1.
> This is the case for step 0 existing at all: the plan would otherwise have
> built a mapping onto a refusal that never happens.

## §7 — Steps

**0. Observe.** ✅ **Done twice** — once before the fix (which is what uncovered
§6.1) and once after, against the deployed alpha API. All four rows captured
verbatim; the post-fix table is §2 above, the bodies are in
[appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md) §8.
Re-runnable as `scripts/probe-appsync-group-gate.mjs`.

**1. Stop if 6.1 answers badly.** ✅ **Done** — it answered badly, this plan was
closed, `done/appsync-group-authorization-unenforced.md` was opened, the fix shipped
in `13926388c` and was verified on a deployment. This plan then reopened. The
remaining steps are the original conformance work, now on a sound premise.

**2. Write the correspondence down as data.** ✅ **Done** —
`reventless/core/src/adapter/Auth/Auth_RefusalVocabulary.res`, a sibling of the
claim-name table it was modelled on. It carries the four observed signals, a
`classify(~httpStatus, ~errorType?, ~extensionsCode?)` that answers
entitlement-vs-identity without the caller knowing which adapter replied, and
`warrantsReauthentication`, the one decision the distinction exists to drive.

**It is a contract, not documentation.** The local adapter now emits
`localEntitlementCode` / `localIdentityCode` from this module rather than
repeating `"FORBIDDEN"` / `"UNAUTHORIZED"` literals, so the table cannot drift
from the code that produces it.

🚨 **The trap the table defuses.** On AppSync the entitlement value
(`Unauthorized`) is a strict prefix of the identity one
(`UnauthorizedException`). A client matching by substring — the obvious thing to
write — collapses them *in the dangerous direction*: it reads "you lack the
role" as "your session is dead" and signs out a caller whose session was fine,
which is exactly the failure §1 set out to prevent. `classify` checks the
transport status first for this reason.

**3. Correct the comments that assert the wrong shape.** ✅ **Done** — eight
claims across both paths said the AWS side emits or enforces `@aws_auth`:
`Api.res` (×2), `PluginSpec.res`, `Dcb_Builder.res`, `local/Platform.res`,
`PlatformGraphQL_Server.res`, `QueryDbResolvers_AppSync.res`,
`Auth_GraphqlContext.res` (×2) and `AppSync_Adapter.res`. One was wrong in a
more interesting way than the rest — it said "AppSync has one rejection to give
and this has two", when AppSync has two as well; they just arrive at different
layers. Also corrected: `AllowAuthenticated` no longer emits *no* directive, it
emits the group-less one.

**4. Cover it.** ✅ **Done** — `reventless/core/tests/adapter/RefusalVocabularyTest.res`,
10 tests. The AWS rows still cannot be asserted from a checkout, so what is
asserted is the *table*: that it names both adapters, that each can express both
refusals, that within an adapter the two are actually distinguishable (a mapping
whose rows look alike to a client would be worthless), and that `classify`
resolves the prefix collision in both directions.

## §8 — Acceptance

- ✅ A deployed AppSync admin query has been observed refusing all four callers
  of step 0, and the captured bodies are recorded — twice, in fact: once with
  the gate open (which is what turned this plan into a security finding) and
  once with it closed. Bodies in
  [appsync-group-authorization-unenforced.md](done/appsync-group-authorization-unenforced.md)
  §1 and §8.
- ✅ §6.1 is answered in writing — "no", and it did outrank this plan. Closed in
  favour of that finding, fixed in `13926388c`, reopened once the premise held.
- ✅ The correspondence is expressed as data both adapters are held to:
  `Auth_RefusalVocabulary.res`, with the local adapter emitting its codes from
  that module rather than repeating literals. Not prose in one adapter's
  comments — and the prose that contradicted it has been corrected in eight
  places.
- ✅ A client can determine "entitlement, not identity" from either adapter
  without knowing which it is talking to — `classify`, covered by 10 tests,
  including the prefix collision that makes the naive check wrong.
- ✅ No gate admits a caller it did not admit before. The only access change in
  this whole line of work was gates that admitted *everyone* starting to refuse
  the unentitled — verified in both directions on a deployment.

**Remaining, and deliberately not done here:** nothing consumes `classify` yet.
The host shell (`80ae9fc`, `3cd0139`) reads the AWS shape directly; pointing it
at this module is the natural next step, but it lives in the UI package and is
its own change. The contract exists and is held to on the emitting side, which
is what stops the two adapters drifting further apart in the meantime.
