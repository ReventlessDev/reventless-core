# Plan: Own a runtime's log group from birth, not after the fact

**Status.** Planned — 2026-08-08. Not started. Written after a managed-log-group rollout
deadlocked in the field: three groups could not be adopted because the runtimes they belong to
kept recreating them faster than a deploy could reach them.

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

## §4 — Adoption, for the estates that already have the problem

Ordering fixes new resources. It does nothing for a group AWS already created, of which there will
be many, and nothing for AppSync at all. So the durable fix needs a second half: when the group
already exists, **adopt it instead of failing**.

The shape is a deploy-time lookup (`aws.cloudwatch.getLogGroup`) that decides between create and
adopt. The mechanism is where the open question is:

**Open question — does a blind `import` option work here?** Pulumi's `import` resource option
adopts an existing resource, but it validates the declared inputs against the live resource and
errors when they differ. An auto-created group has **no retention and no tags**, while the
declared resource has both — so the inputs differ by construction, and import may reject exactly
the case this exists to serve. Three candidate resolutions, in preference order, and this needs a
spike before the plan commits:

1. Import with the *observed* inputs and let the following update apply retention and tags, if the
   engine permits import-then-update in one deployment.
2. Import under `ignoreChanges` for the drifting fields, then drop the ignore in a later deploy.
3. Fall back to an out-of-band `pulumi import`, documented as a runbook rather than automated —
   the weakest option, because it puts a manual step on the recovery path for a failure the
   framework caused.

Whichever wins, the behaviour to guarantee is: **a deploy that meets an existing log group adopts
it and reports that it did, rather than failing.**

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

- A stack deployed from scratch never emits `CreateLogGroup` for a group AWS created first, under
  any invocation load — verified with a runtime that is invoked during its own deploy.
- A stack whose groups were auto-created deploys to green without manual intervention, and the
  groups end up in state with the declared retention and tags.
- A deploy that fails for an unrelated reason, is left for an hour with live traffic, and is then
  re-run, succeeds — the scenario §1.3 describes.
- Replacing a function does not leave an orphan log group.
- `unmanagedLogGroupStacks` still works for a stack that has adopted nothing, and its
  documentation states that it must not be set once adoption is partial.
- No call site outside the three in §1 changes.

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
