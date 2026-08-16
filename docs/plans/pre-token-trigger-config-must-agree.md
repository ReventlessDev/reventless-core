# Plan: the pre-token trigger's two fields must agree, and the merge must be a fixpoint

**Status.** Implemented + unit-tested 2026-08-16, **not yet verified against a
live pool.** All three changes below are in
`Auth_ActiveRolePoolAttachment`, the suite goes 22 → 31 tests, and the full core
suite is green.

Not done, and the gap is the one the Risk section names: every test here
exercises the pure merge, which was never the part AWS rejected. Nothing has yet
sent an `UpdateUserPool` at a pool carrying a `PreTokenGenerationConfig`. This
belongs in `done/` once a deploy attaches the trigger to a BYO pool and
succeeds — not before.

One defect with three faces. They land together because the read path and the
write path have to agree on the same answer or refresh fights the update
forever.

**Goal.** Attaching the active-role trigger to a BYO pool succeeds on a pool
that already carries a `PreTokenGenerationConfig`, and keeps succeeding on every
deploy afterwards.

---

## Why — a deploy that has now failed three times

`Deploy Platform` fails at `pulumi up` creating `ActiveRolePoolAttachment`:

```
error: Cannot use PreTokenGenerationLambda and PreTokenGeneration with
       different Lambda function ARN's
```

Cognito carries the pre-token trigger in **two** places:

| field | shape |
| --- | --- |
| `PreTokenGeneration` (legacy) | `"arn:aws:lambda:…"` |
| `PreTokenGenerationConfig` (V2) | `{ LambdaArn, LambdaVersion }` |

`UpdateUserPool` accepts either, and rejects the call when both are present
naming **different** functions. `mergedUpdateInput` writes only the legacy field
and copies the described `LambdaConfig` back wholesale — so a pool that already
carries a `PreTokenGenerationConfig` gets the customer's old ARN in the V2 field
next to ours in the legacy one, and AWS refuses the update.

The string `PreTokenGenerationConfig` appears **nowhere** in this repo. Nothing
reads it, writes it, or clears it.

### The part that makes this structural, not a missed case

Writing one field while copying the other back verbatim can never be stable,
because **AWS materialises the field we did not write.** Attach via the legacy
field alone and the next `DescribeUserPool` returns a `PreTokenGenerationConfig`
anyway, populated by the service. The merge then feeds that back on the
following deploy — so a pool this resource attached successfully once can fail
the *next* time, with nothing having changed but AWS normalising its own record.

The merge is a fixpoint problem. The only form stable under repeated
describe → merge → update is one that writes **both** fields, in agreement.

## Why V1_0 specifically

`Auth_ActiveRoleTrigger_Ops` implements the `V1_0` contract — it returns
`claimsOverrideDetails`, and says so deliberately:

> **Version 1 of the trigger, deliberately.** Group override and added ID-token
> claims are `V1_0` capabilities; `V2_0`/`V3_0` buy access-token customisation
> this does not need and are gated behind the Essentials and Plus feature plans.
> A deployment on the Lite tier must not be excluded from acting as a role.

That decision now has a second reason behind it. A pool left at `V2_0` pointing
at this handler does not fail — Cognito sends a V2 event, the handler answers
with a V1 `claimsOverrideDetails`, and the service **ignores it**. Sign-in
succeeds, tokens mint, and the role narrowing silently does not happen. That is
the failure shape this resource is written to refuse everywhere else, arriving
through the one field nothing looked at.

So the version is not the customer's to keep. The trigger and its contract are
one unit, and this resource owns both.

---

## The change

### 1. Write both fields, pinned to V1_0

In `mergedUpdateInput`, attaching sets

```rescript
lambdaConfig->Dict.set("PreTokenGeneration", JSON.Encode.string(arn))
lambdaConfig->Dict.set(
  "PreTokenGenerationConfig",
  JSON.Encode.object(/* LambdaArn = arn, LambdaVersion = "V1_0" */),
)
```

and detaching deletes **both**. The existing detach deletes only the legacy key,
which leaves the destroyed Lambda attached through the V2 field — verbatim the
"every sign-in fails on a pool nothing in this deployment would fix" hazard the
`delete_` doc comment already names.

The pool's *other* triggers keep being carried through untouched. Only the two
fields naming this one trigger are written.

### 2. Read the V2 field first, and treat a foreign version as unattached

`attachedTrigger` reads only the legacy field, so a V2-configured pool reports
`""`, refresh records spurious drift, and the next `up` re-sends the conflicting
write — the loop that turns this from a one-deploy failure into a permanent one.

It should prefer `PreTokenGenerationConfig.LambdaArn`, fall back to the legacy
field, and report `None` when `LambdaVersion` names a version this handler does
not implement. Reporting `None` is what makes a wrong-version pool show as drift
and get rewritten on the next `up` — the silent-no-op case above heals itself
instead of persisting.

### 3. Tests for the case that has none

`Auth_ActiveRolePoolAttachmentTest` has no fixture carrying a
`PreTokenGenerationConfig`, which is exactly why this shipped. Add, against a
described pool that carries one:

- attaching leaves the two fields naming the **same** ARN — the property AWS
  enforces, asserted directly rather than via the error text;
- attaching pins `LambdaVersion` to `V1_0`, including when the pool arrived at
  `V2_0`;
- detaching removes **both** fields;
- `attachedTrigger` reads the V2 field;
- `attachedTrigger` reports `None` for a `V2_0` pool pointing at our ARN;
- the merge is idempotent — feeding its own output back in produces input AWS
  still accepts. This is the fixpoint property, and it is the one that would
  have caught the defect.

The bare-pool test asserts `LambdaConfig` equals a single-key object and must
move to the two-key form.

---

## Scope

`reventless/aws/src/adapter/Auth/Auth_ActiveRolePoolAttachment.res` and its test.
No change to `Auth_ActiveRoleTrigger_Ops` — the handler's contract is already
right and is now depended on explicitly. Auto mode is untouched:
`Cognito_UserPool.lambdaConfig` exposes only `preTokenGeneration`, and
`Platform_Stack` sets just `preSignUp` there, so no pool the framework owns
reaches the V2 field at all.

## Risk

The write path is exercised only against a live BYO pool. `mergedUpdateInput`
and `attachedTrigger` are pure and total for that reason, so every branch above
is checkable without a pool — the deploy is the first place the SDK call itself
runs.
