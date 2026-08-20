# Plan: Own a runtime's log group from birth, not after the fact

**Status.** Implemented — 2026-08-08. Written after a managed-log-group rollout deadlocked in the
field: three groups could not be adopted because the runtimes they belong to kept recreating them
faster than a deploy could reach them.

**On-AWS verification run 2026-08-20 — §6 passes on every criterion but one** (see §6). The
outstanding item is the **sweep**, and it is blocked rather than forgotten: the auto-created groups
cannot be swept while their functions are still writing to them, and those functions have no managed
group because `unmanagedLogGroupStacks: alpha` suppressed it. Removing that var landed in
`0bc73d444`; the sweep is runnable one deploy later. Tracked from the other side in
[env-tiered-log-retention-and-levels.md](env-tiered-log-retention-and-levels.md).

**Goal.** A framework-provisioned runtime's CloudWatch log group is created and owned by the
deploy, with no window in which AWS can create it first — and an estate whose groups AWS already
created has a supported way back.

**Non-goal.** Retention tiering and log levels. Those are settled in `Util_LogRetention` and this
plan changes neither. The question here is *ownership and ordering*, not policy.

---

## §1 — The defect: a create that races an auto-create, and loses

Three sites create a log group **after** the resource it belongs to:

| Site | Group |
| --- | --- |
| `reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res:344` | `/aws/lambda/<function>` for every runtime |
| `reventless/aws/src/util/Util_LambdaLogging.res:71` | the same, for support Lambdas |
| `reventless/aws/src/components/Api/AppSync_Adapter.res:564` | `/aws/appsync/apis/<id>` |

All three derive the group's name from a **physical output** — `lambda.name`, `graphQLApi.id` —
which is only known once the resource exists. The ordering is therefore forced: resource first,
group second. `RuntimeEnvironment_Lambda.res:320-325` states the reason plainly, and it is a good
one: `Lambda.Function` has no `name` argument, so its physical name always carries Pulumi's
`-<7hex>` suffix, and a literal `/aws/lambda/${name}` would create an empty group beside the real
one.

But AWS creates `/aws/lambda/<function>` **on the function's first invocation**. So the window
between "function exists" and "group created" is a window in which any invocation takes the name
first, and the deploy's `CreateLogGroup` then fails:

```
InvalidParameterException → ResourceAlreadyExistsException:
The specified log group already exists
```

Three properties make this worse than an ordinary flake:

1. **It does not heal on retry.** The group persists, so every subsequent attempt fails
   identically. This is not a transient condition that a re-run clears.
2. **It is most certain for the runtimes that matter most.** A runtime with a heartbeat, a stream
   subscription or a scheduled trigger is invoked within seconds of existing. The busier the
   component, the more reliably the deploy loses — so the failure selects precisely for the
   components an operator most wants managed.
3. **An unrelated failure converts into a permanent one.** If a deploy fails anywhere in the stack
   for any reason, the runtimes it already created stay live and keep logging. Their groups are
   then auto-created and unadopted, and the *next* deploy fails on the group rather than on the
   original problem — which is a different and more confusing error than the one that started it.

The consequence is a stack that cannot deploy at all, from a subsystem nobody was changing.

## §2 — Why the existing escape hatch cannot be the answer

`unmanagedLogGroupStacks` (`Util_LogRetention.parseUnmanagedStacks`, honoured at all three sites)
makes the program stop **declaring** log groups. That is the right bridge for a stack that has
never adopted any group.

It is actively harmful once adoption is **partial**, which is exactly the state a raced deploy
leaves behind. With some groups already in state, "stop declaring them" reads to the engine as
*removed from the program*, and the next deploy **deletes** them — taking their retention settings,
their tags, and any metric filters attached to them. So the hatch is unavailable in precisely the
situation that produces the failure.

The hatch should stay for greenfield adoption, and this plan should make reaching for it
unnecessary.

## §3 — The fix: name the group ourselves, and create it first

AWS Lambda's Advanced Logging Controls let a function be told which log group to write to
(`loggingConfig.logGroup`). That inverts the ordering the defect depends on:

```
  today:   Function  ──►  (AWS may auto-create)  ──►  LogGroup   ✗ races
  with it: LogGroup  ──►  Function(loggingConfig.logGroup = it)   ✓ cannot race
```

A function configured with a log group at creation never causes an auto-create, because it has
somewhere to write from its first invocation. There is no window.

This also dissolves the reason the group's name had to be physical. Once we choose the name, it can
be **logical and stable** — which additionally fixes a second-order problem the current code
tolerates: when a function is replaced, its physical name changes, and the old group is left behind
as an orphan that nothing tears down.

**Binding gap.** `rescript/pulumi-aws/src/Lambda/Lambda.res:218-232` has no `loggingConfig` field.
Adding it is part of this work.

**AppSync is not covered by this and needs §4.** An AppSync API's log group name derives from a
server-assigned id, and the service offers no equivalent "write here" knob. That site can only be
made safe by adoption, not by ordering.

### Implemented — 2026-08-08

`loggingConfig` is on the binding; `Util_LambdaLogging` creates the group first and returns the
`loggingConfig` that points a function at it; both Lambda sites and the six bespoke builders that
route through them are rewired. The chosen name is `/aws/lambda/<stack>-<component>`
(`Util_LambdaLogging.logGroupNameFor`, unit-tested).

One consequence deserves stating, because it changes what §4 is *for*: the chosen name is one AWS
never produces — the service auto-creates `/aws/lambda/<physical name>`, and a physical name always
carries the `-<7hex>` suffix. **So on the Lambda sites there is nothing left to adopt**, on any
stack, including one whose groups AWS already created. The create cannot collide.

What that leaves behind is the mirror of the problem: those already-auto-created groups are now
written to by nothing and managed by nothing, and they carry no retention — the unbounded-storage
outcome §5 rejects. They need a deliberate sweep once the first deploy on the new naming lands;
this is an operational step, recorded in §6.

## §4 — Adoption, for the estates that already have the problem

Ordering fixes new resources. §3 turned out to fix the Lambda sites outright — a name AWS never
mints has nothing to adopt. **AppSync is what remains**, and it remains structurally: its group
name is `/aws/appsync/apis/<server-assigned id>`, so the group can only ever be created after the
API, and any window in which the API serves a request before the deploy reaches the group is a
window the deploy loses permanently.

The behaviour to guarantee is unchanged: **a deploy that meets an existing log group adopts it and
reports that it did, rather than failing.**

### Spike result — the `import` option cannot be wired in-program

The plan's open question was whether Pulumi's `import` resource option tolerates inputs that differ
from the live resource. It does: import-then-update in one deployment is the documented behaviour,
so candidate 1 was correct and candidates 2 and 3 were unnecessary. That is not the blocker.

The blocker is one the plan did not anticipate: **`import` takes a plan-time `string`**, and neither
thing this needs is available as one at resource-declaration time.

- *"Does the group already exist?"* — `aws.cloudwatch.getLogGroup` returns a `Promise`, and
  `getLogGroupOutput` an `Output`. A resource declaration is synchronous, so the create-vs-adopt
  branch cannot be taken. Passing `import` unconditionally is not a fallback: importing a resource
  that does not exist is itself an error.
- *The AppSync group's name* is derived from `graphQLApi.id` — an `Output`, never a string.

Two candidate mechanisms survive that. Preloading the live group names through a top-level-`await`
companion module would make the branch synchronous, but it only reaches AppSync if api ids are also
preloaded and matched back to logical names by prefix — fragile, and it puts an AWS call on every
program start.

### The mechanism: make create-or-adopt a non-question

The chosen shape sidesteps the branch entirely. A log group's *retention and tags* can be applied
with calls that are indifferent to whether the group already exists — `PutRetentionPolicy`,
`TagResource`, and `CreateLogGroup` tolerated when it reports `ResourceAlreadyExists`. A resource
whose create step does that is idempotent by construction: there is no case to detect, so nothing
has to be known synchronously, and the group name can be a plain `Output` because it arrives as a
resource **input** rather than a resource **option**.

Delete tears the group down, so the resource keeps the teardown behaviour the declarative
`Cloudwatch.LogGroup` had, and `unmanagedLogGroupStacks` keeps its meaning.

The known cost is that a Pulumi dynamic provider runs from a serialized closure captured in state:
a source fix reaches only resources that are subsequently created or updated. That constrains how
its create/update steps may be changed later, and is worth a comment at the definition.

### Implemented — 2026-08-08

`Util_LogGroup_Adopting`, mirroring the dynamic-provider shape already established by
`AppSync_SourceApiAssociation_Retrying` (lazy SDK import so the closure stays serializable,
hand-rolled backoff, aliases the classic type so state migrates in place rather than
delete-then-recreate). `AppSync_Adapter` is the one call site.

A `pulumi preview` against the `alpha` hybrid stack is what confirms it, and it did so more
directly than expected: the stack's `PlatformApiAppSyncLogGroup` resolves to
`/aws/appsync/apis/47xi7skgqzapponhwpybvjxcny`, **a group that exists in the account and is not in
the stack's state**. That is the deadlock itself, still live — the classic resource's create
against that name is exactly the `ResourceAlreadyExists` failure this plan was written for. The
preview plans it as a create the adopting provider absorbs.

The same preview shows the §3 half behaving: log groups plan as clean creates under the new names
(no replace of the old ones — they were never in this stack's state, because the deploy that would
have created them is the one that deadlocked), and every function takes `loggingConfig` as an
in-place update.

## §5 — Rejected alternatives

- **Delete the group and immediately create it.** This is what the failure tempts an operator into,
  and it is a trap: it destroys the log history, and it still races — a runtime under any load
  recreates the group within seconds, so the deploy has to win a footrace it cannot influence.
  Observed to fail three times consecutively against a heartbeat-driven runtime.
- **Swallow the `ResourceAlreadyExists` error and continue.** The group then exists with no
  retention, which is unbounded CloudWatch storage billed forever — the precise outcome
  `Util_LogRetention`'s tiering exists to prevent. A silent success that costs money indefinitely is
  worse than a loud failure.
- **`retainOnDelete`.** Addresses teardown, not creation. Irrelevant to this defect.
- **Give the function a fixed physical `name`.** Removes the suffix problem but reintroduces
  cross-stack collisions in a shared account, which is why the physical-name derivation was chosen
  in the first place (`RuntimeEnvironment_Lambda.res:320-325`).

## §6 — Acceptance

Measured against deployed `alpha`, 2026-08-20.

- ✅ A stack deployed from scratch never emits `CreateLogGroup` for a group AWS created first, under
  any invocation load. Structural, per §3: the chosen name is one the service never produces, so
  there is nothing to collide with. 35 managed groups exist, created cleanly.
- ✅ A stack whose groups were auto-created deploys to green without manual intervention, and the
  groups end up in state with the declared retention and tags. **35 / 35 carry retention**, and the
  tags are the full set (`reventless:role: Logs`, plus component / plugin / kind / environment /
  platform).
- ⚠️ A deploy that fails for an unrelated reason, is left for an hour with live traffic, and is then
  re-run, succeeds — the scenario §1.3 describes. **Not observed, and not reachable on the Lambda
  path**: the same property that satisfies criterion 1 removes the failure mode this describes. It
  remains meaningful for AppSync, whose name comes from a server-assigned id — covered by §4's
  create-or-adopt.
- ✅ Replacing a function does not leave an orphan log group. **35 managed groups, 35 functions
  pointing at one, 35 distinct targets, and zero groups nobody writes to** — the managed name is
  stable across the physical-name hash change, which is the whole point.
- ❌ The groups AWS auto-created before this change are swept once the first deploy on the new naming
  has landed. **Blocked, not forgotten.** 39 auto-created groups remain and **none is sweepable**:
  every one still has a live function writing to it, because `unmanagedLogGroupStacks: alpha` kept
  those functions off the managed path. Removing that var landed in `0bc73d444`; the sweep is
  runnable one deploy later. (The 9 that *were* written to by nothing — from stacks destroyed the
  same day — were deleted, 249.3 MB.)
- ✅ `unmanagedLogGroupStacks` still works for a stack that has adopted nothing, and its
  documentation states that it must not be set once adoption is partial —
  [`Util_LogRetention.res`](../../reventless/aws/src/util/Util_LogRetention.res#L72-L76), in stronger
  terms than this line asked for: it names the consequence (the next deploy deletes the groups with
  their retention, tags and metric filters).
- ✅ No call site outside the three in §1 changes.
- ✅ **§4, AppSync.** Every live API's group carries retention. The only three without belonged to
  deleted APIs and were swept 2026-08-20.

### The near-miss this measurement turned up

`alpha` sat for 18 days in exactly the state the documentation above forbids — hatch set, 35 managed
groups in state. It survived only because all 35 are declared through
`makeManagedLogGroup`'s `retentionDaysOverride` branch, which ignores the hatch by design, so they
were never un-declared and no deploy proposed deleting them. Had those groups come through the tier
branch instead, the next deploy would have deleted 35 log groups with their retention, tags and DCB
metric filters. The warning is correct; the estate was one code path away from needing it.

---

## Appendix: code anchors (2026-08-08)

| Fact | Anchor |
| --- | --- |
| Runtime log group, created after the function | `reventless/aws/src/adapter/Runtime/RuntimeEnvironment_Lambda.res:344-354` |
| Why the name is physical, not logical | `RuntimeEnvironment_Lambda.res:320-325` |
| Support-Lambda log group, same shape | `reventless/aws/src/util/Util_LambdaLogging.res:55-80` |
| AppSync log group, name from a server-assigned id | `reventless/aws/src/components/Api/AppSync_Adapter.res:564-570` |
| The escape hatch, honoured at all three sites | `Util_LogRetention.parseUnmanagedStacks`; `RuntimeEnvironment_Lambda.res:156`, `Util_LambdaLogging.res:16`, `AppSync_Adapter.res:560` |
| Retention/level policy this plan does not touch | `reventless/aws/src/util/Util_LogRetention.res` |
| Lambda binding without `loggingConfig` | `rescript/pulumi-aws/src/Lambda/Lambda.res:218-232` |
| Metric filters attached to the managed group | `RuntimeEnvironment_Lambda.res:356-372` |

## Appendix: what the work landed on (2026-08-08)

| Fact | Anchor |
| --- | --- |
| `loggingConfig` on the binding | `rescript/pulumi-aws/src/Lambda/Lambda.res` (`Function.loggingConfig`) |
| Group created first; the config that points a function at it | `Util_LambdaLogging.makeManagedLogGroup` / `loggingConfigFor` |
| The chosen name | `Util_LambdaLogging.logGroupNameFor`, tested in `Util_LambdaLoggingTest.res` |
| Create-or-adopt for AppSync | `reventless/aws/src/util/Util_LogGroup_Adopting.res`, tested in `Util_LogGroup_AdoptingTest.res` |
| The one adopting call site | `AppSync_Adapter.res` (`${name}AppSyncLogGroup`) |
| Operator runbook: tiers, ownership, the sweep | `packages/doc/docs-infrastructure/lambda-deployment.md` §11 |
