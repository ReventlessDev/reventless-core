# Plan: the first admin should not need the console

**Date:** 2026-09-10
**Status:** filed, not started.
**Repos:** `reventless-core` only.

**Goal.** A developer deploys, runs **one command**, and signs in as an administrator who can see
everything. Today they deploy, cannot sign in, and are told nothing about why.

**Non-goal.** Administering users *after* the first one. Creating the second and hundredth account is
what `IdentityProvider` is being built for — see
[identity-is-a-capability-not-a-cognito-handle.md](identity-is-a-capability-not-a-cognito-handle.md) —
and a runtime console for it is a separate concern again. This plan is about the bootstrap only: the
step that has to happen before anything else can, and that currently has no owner.

**Why it is worth its own plan.** Every other gap in this area is about scale. This one is about
whether a stranger evaluating the framework ever gets past their first deploy — and the failure is
silent, which makes it the most expensive kind of first impression.

---

## 1. The gap, measured

After `pulumi up` in auto mode the stack creates a user pool and an app client, and **nothing else**.
Measured in-repo rather than assumed:

| Claim | Evidence |
|---|---|
| No group is ever created | `Util_CognitoGroupUser.addUserGroup` exists and **has no callers** — it is re-exported through `Util.res` and nothing reaches it |
| No user is ever created | `Util_Cognito_Runtime.signUpIfMissing` exists and **has no callers** either |
| Nothing documents the manual path | no page in `docs/guides/` or `packages/doc/docs-app/` covers first sign-in; the closest reference is a line in a completed plan describing "a manually-created user" |
| The intended answer is the console | `Platform_Stack.res`'s own doc comment: *"Caller is responsible for creating groups (`Admin`, `User`, …) and users via the AWS console / CLI"* |

So the first-run experience is: deploy succeeds, the app loads, sign-in fails, and nothing anywhere
says what to do. Two helpers that would have done the work are already written and simply never wired.

**This is an AWS-only gap, and that is also why it has gone unnoticed.** The local platform ships a
built-in `adminUser` — `local-admin`, in `["Admin", "User"]` — so a developer working locally has an
administrator from the first minute and never meets the question. The gap appears only on the first
cloud deploy, which is precisely the moment a newcomer is least equipped to diagnose it and most likely
to conclude the framework is broken. Nothing in this plan applies to the local platform, and that is a
finding rather than an omission.

**And the manual path has a step that is easy to miss.** An administrator-created Cognito user lands in
`FORCE_CHANGE_PASSWORD`, so even a developer who finds the console and creates a user correctly then
hits a password-change challenge on first sign-in. Getting out of it needs a second, separate call.

## 2. The trap underneath it: admin-ness is decided twice

Two independent mechanisms both have to agree, and **nothing checks that they do**:

1. **Authorization** — the literal `"Admin"`, written out in **four framework sites across three
   packages**: `PluginsReadModelSpec`'s `@@reventless.authorize(AllowGroups(["Admin"]))` in `core`,
   `Platform.res`'s `~group="Admin"` for the admin API in `aws`, and — easy to miss —
   `PlatformGraphQL_Server`'s `requireGroup(~group="Admin")` and `LocalAuth`'s default
   `groups: ["Admin", "User"]` in `local`. **The two platforms hard-code the same name
   independently**, which is its own reason for a shared constant: nothing today would notice if one
   moved.
2. **Visibility** — `REVENTLESS_ELEVATED_GROUPS`, read through `OwnerScope.elevatedGroups()`, which
   decides who is exempt from `@owner` scoping.

A developer who names their group `Administrators` satisfies neither and is told nothing useful. One
who names it `Admin` but never sets the environment variable gets an administrator who passes every
authorization check and then sees **empty screens**, because every owner-scoped view filters them out.
That second shape is not hypothetical — it is a defect this project has already hit.

**The delivery half is already built, which is what makes this cheap.**
`RuntimeEnvironment_Lambda` calls `Util_OwnerScopeEnv.applyElevatedGroupsDefault`, so whatever the
deploy program holds in `OwnerScope.elevatedGroups()` is baked into every Lambda's environment. The
residue named in `done/owner-scoped-identity-and-reads.md` — *"the AWS runtime builder must pass
`REVENTLESS_ELEVATED_GROUPS` to every Lambda"* — is closed. What is missing is that **nothing ever puts
a value in**. The pipe is laid and dry.

## 3. Steps

### Step 1 — one name, not four literals

The administrator group's name as one definition. **In `spec`, not in `aws`** — both platforms
hard-code it today, so a constant that only `aws` can reach would leave the `local` copies exactly as
divergent as they are now. That is the difference from `Auth_LoginIdentifier`, whose consumers are both
inside `aws`.

🚨 **The name itself cannot change, and the plan must not pretend otherwise.** `"Admin"` is written into
every example's authorization annotations, so it is effectively public contract; renaming it is a
different and much larger act. This step buys agreement and a single place to read, **not** the freedom
to pick a new name.

🚨 **One consumer cannot be deduplicated at all.** A PPX annotation takes a literal, so
`@@reventless.authorize(AllowGroups(["Admin"]))` cannot reference a constant. The constant's job is to
make everything *else* agree with the annotation, and **a test must assert that the constant equals the
literal the annotations use.** Without that test this step adds a second place to be wrong rather than
removing one.

### Step 2 — the stack declares the groups

Call the `addUserGroup` that already exists. In **auto** mode only, and that restriction is the point:

| Pool | Who creates the group | Why |
|---|---|---|
| Auto (`HostUiPool`) | the stack, as a declared resource | the pool is ours; the group is an ordinary child resource |
| BYO / supplied | the provisioning script (Step 4) | two stacks pointed at one shared pool would both declare the same group, and the second would fail on a name that already exists |

That is the same split `Auth_SignUpMode` already uses, for the same underlying reason: on a pool the
stack does not own, pool-level facts are not the stack's to declare.

### Step 3 — the stack elevates the admin group by default

With Step 2's group declared, the stack defaults `OwnerScope.setElevatedGroups([adminGroup])`, so
`applyElevatedGroupsDefault` bakes `REVENTLESS_ELEVATED_GROUPS=Admin` into every Lambda without anyone
naming it. This is the step that closes the "administrator sees empty screens" trap for good.

**Default it, never force it.** An explicit `setElevatedGroups` in a platform root means what it says
and must win — the same contract `applyElevatedGroupsDefault` already keeps with per-Lambda overrides.
A deployment that deliberately elevates nobody keeps that answer.

🚨 **Ordering, and this stack has been burned by exactly this before.** The value must be set before the
runtime builder composes any Lambda's environment. `Platform_Stack` already carries a scar from a
related mistake — a pool-resolution result that is process-cached, so a feature's existence came to
depend on *which caller resolved the pool first*, and the feature silently vanished from the deploy with
no error and no resource. Whatever wires this must not hinge on call order. If that cannot be
guaranteed structurally, set it at the platform entry point rather than inside pool resolution.

*Already budgeted:* `Util_LambdaEnvBudget` names `REVENTLESS_ELEVATED_GROUPS` as "set for every Lambda",
so the environment-size ceiling has accounted for it. This step spends no new budget; it fills a slot
already reserved.

### Step 4 — one command makes the first admin

`--admin-email` on `scripts/ProvisionIdentity.res`, which already provisions pools and already carries
the other first-deploy identity choices. It must do **all four** of these, because doing three leaves
the developer stuck in exactly the place the console leaves them:

1. create the group if it is missing (this is the BYO half of Step 2)
2. create the user
3. **set a permanent password**, so the account does not land in `FORCE_CHANGE_PASSWORD` and meet a
   challenge the host UI may not handle
4. add the user to the group

Then print the sign-in details, once.

**The password is the open question, and both answers have a cost.** Generating one and printing it is
friendliest for the target case — a developer at a terminal — but a printed secret lands in scrollback
and, if anyone runs this in CI, in a build log. Taking `--admin-password` avoids the log and puts it in
shell history instead. **Recommendation: generate and print, and say plainly in the output that it is a
bootstrap credential to be changed.** The target of this plan is a laptop, not a pipeline; a deployment
that cares should be using its own provisioning anyway. Revisit if this ever runs unattended.

*Check before building:* whether the SDK binding for setting a permanent password exists in
`rescript-aws-sdk`, and add it if not. Do not substitute a temporary password and call it done — that
reproduces the defect this step exists to remove.

### Step 5 — the deploy says what is left

A stack output naming the administrator group, so the value is readable without reading source. The
existing `OwnerScopeDiagnostics.warnIfNoElevatedGroups` then keeps its job for deployments that opt out
of Step 3's default — after this plan it should be *silent* on a default auto deployment, which makes
it a real signal again rather than a warning everyone learns to ignore.

### Step 6 — the page that says all of this once

`packages/doc/docs-app/first-admin.md`, on the published site rather than in `docs/guides/`: the
audience is someone evaluating the framework, and internal guides are not where they look. Linked from
`get-started.md` (the page they are already on) and from `authorization.md` (which documents
`REVENTLESS_ELEVATED_GROUPS` today without saying who sets it).

It must cover, in this order:

- what a deploy creates, and what it deliberately does not
- the one command, with its output
- signing in, and what to expect the first time
- **adding more users today** — the console, honestly, with a pointer to the capability that will
  replace it. Leaving this out is what makes the current state feel like a bug rather than a boundary
- what changes on a supplied pool, since none of the auto-mode conveniences apply
- the two mechanisms behind "who is an administrator", and why a deployment overriding one should
  override both

## 4. Verification

- A fresh auto-mode deploy, followed by the one command, ends with a successful sign-in and an
  administrator who can read an `@owner`-scoped view belonging to somebody else. That last clause is the
  test — it is the half that silently failed before, and a sign-in alone does not exercise it.
- Every Lambda in a default auto deployment carries `REVENTLESS_ELEVATED_GROUPS`, asserted on the
  composed environment rather than by reading the deploy log.
- A deployment that calls `setElevatedGroups` explicitly keeps its own answer, including the empty one.
- The constant in Step 1 equals the literal the platform's authorization annotation uses — held as a
  test, since the compiler cannot check across that boundary.
- Running the command twice is not an error: the group already exists, the user already exists, and
  neither is a failure worth stopping a bootstrap over.
- Full build warning-free, whole suite green, format gate green.

## 5. Honesty ledger

- **Read off code:** that `addUserGroup` and `signUpIfMissing` have no callers; that
  `RuntimeEnvironment_Lambda` calls `Util_OwnerScopeEnv.applyElevatedGroupsDefault` and that
  `Util_OwnerScopeEnv.entry` derives from `OwnerScope.elevatedGroups()`; that `"Admin"` is a literal in
  four framework sites across `core`, `aws` and `local`, and in every example's annotations; that
  `Platform_Stack`'s doc comment names the console as the answer; that `Util_LambdaEnvBudget` already
  counts the variable; that no page in `docs/guides/` or `packages/doc/docs-app/` covers first sign-in.
- **Corrected while filing, worth not re-deriving:** `Auth_ActiveRole`'s `Some("Admin")` looks like a
  fifth site and is not — it is a row in a test table where the name is arbitrary. The `local` platform's
  two copies are the ones that are easy to miss, and they are the reason Step 1 lands in `spec`.
- **Also read off code, and it reframes the whole plan:** `LocalAuth.adminUser` exists, so the local
  platform has no bootstrap problem. This is an AWS-first-deploy gap specifically, which explains both
  why it survived and why it is expensive: the people who hit it are the ones with the least context.
- **Asserted from outside this repo:** that an administrator-created Cognito user lands in
  `FORCE_CHANGE_PASSWORD` and needs a separate call to receive a usable password. It decides Step 4's
  third bullet, so **confirm it against a real pool before building** — if it is wrong, that step gets
  simpler, and nothing else in this plan moves.
- **Not investigated:** whether the host UI's sign-in flow handles a password-change challenge at all.
  Step 4 avoids the question rather than answering it, which is the right trade for a bootstrap but
  leaves the flow untested for any *other* path that produces the same challenge — an administrator
  resetting somebody's password, for instance.
- **Design proposal, not validated:** the module and flag names, and the choice to put the BYO group
  creation in the provisioning script rather than in a stack resource. The second follows the split
  `Auth_SignUpMode` already made, so it is consistent rather than independently justified.
