# Plan: Scope the CommandTopic Queue Policy's EventBridge Send Grant

**Status**: code + tests landed and deployed to alpha 2026-07-22; conditions
confirmed live on the deployed queues (see Deploy evidence). Step 3 — observing
an actual scheduled delivery under the new conditions — is still outstanding.
A wrong condition fails closed and silently, so a correct-looking policy is
necessary but not sufficient evidence.

**Discovered**: 2026-07-22, while tracing the SQS `QueuePolicy` destroy race
(orphaned `AdminEventColl` / `AdminDcbCmdTopic` policy deletes after the
`Admin*` -> `Platform*` rename).

**Sibling item**: the dependency-edge fix for the same five `QueuePolicy` call
sites (resources constructed inside `Pulumi.Output.apply`, `queueUrl` passed as
an unwrapped string). Independent of this plan — that one is about destroy
ordering, this one is about the policy's contents.

## Problem

[`CommandTopicChannel_Helpers.res`](../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res)
attached an unconditioned service-principal grant to every CommandTopic queue
(line anchors omitted — the statement moved when the fix landed):

```rescript
{
  sid: "AllowCloudWatchEventsToSendToQueue",
  effect: Allow,
  principal: Principals({service: PrincipalId("events.amazonaws.com")}),
  actions: Actions(["sqs:SendMessage"]),
  resources: Resource(queueArn),
}
```

No `Condition` block — `conditions` is optional on the statement type
([`PolicyDocument.res:114`](../../rescript/pulumi-aws/src/IAM/PolicyDocument.res#L114)),
and it is genuinely absent here rather than defaulted. The grant therefore
authorises the EventBridge service principal globally: any EventBridge rule
that names this queue as a target can deliver into it, including rules in
other AWS accounts. This is the standard confused-deputy shape that
`aws:SourceArn` / `aws:SourceAccount` conditions exist to close.

It is the **only** unconditioned statement in the AWS adapter's queue policies.
Every sibling scopes its principal:

| Policy | Principal | Condition |
|---|---|---|
| CommandTopic — `AllowLambdaToAccessQueue` | `lambda.amazonaws.com` | `arnEquals` on the function ARN |
| CommandTopic — `AllowCloudWatchEventsToSendToQueue` | `events.amazonaws.com` | **none** |
| EventCollector — `AllowReceiveSnsEvents` | `sns.amazonaws.com` | `SourceAccount` + `ArnLike` on topic ARN |
| DeadLetterQueue — `AllowLambdaToAccessQueue` | `lambda.amazonaws.com` | `arnEquals` on the handler ARN |

## Why the grant exists (do not simply delete it)

It is load-bearing. The scheduler creates EventBridge rules **at runtime**, not
at deploy time, and targets the command topic queue directly —
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:38-60`](../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L38-L60)
issues `PutRuleCommand` + `PutTargetsCommand` with `arn: resource.urn` over the
queue resources handed to it. For SQS targets EventBridge authorises against the
queue's resource policy, so removing the statement breaks scheduled publishing.

(The heartbeat path is unaffected either way — its EventBridge rule targets a
Lambda, which then sends to the queue under its own execution role. See
[`HeartbeatRunner_CloudWatchEvents.res:86-96`](../../reventless/aws/src/plugin/heartbeat/HeartbeatRunner_CloudWatchEvents.res#L86-L96).)

Because rule names are chosen at runtime (`schedule.name`), the fix cannot pin a
single rule ARN at deploy time.

## Goals

- The `events.amazonaws.com` grant is scoped to the deploying account.
- Scheduled publishing continues to work end-to-end (rule created at runtime,
  message lands in the command topic queue).
- The scoping pattern matches the EventCollector precedent so the four policies
  read consistently.

## Non-goals

- Migrating `ScheduledPublisher` to EventBridge Scheduler — tracked separately
  in [`aws-adapters-critical-fixes.md`](Backlog/aws-adapters-critical-fixes.md) as a
  long-term item.
- Pinning individual rule ARNs. Rule names are runtime-chosen; wildcard-within-
  account is the achievable bound.
- The `resolvedResource.urn`-carries-an-ARN type gap (finding #6 of
  `aws-adapters-critical-fixes.md`), which this code path also relies on.

## Approach

Mirror `EventCollectorChannel_Helpers.createQueuePolicy`: derive the account id
from the queue ARN (segment index 4) and add both conditions.

```rescript
{
  sid: "AllowCloudWatchEventsToSendToQueue",
  effect: Allow,
  principal: Principals({service: PrincipalId(AWS.CloudwatchEventRule.principal)}),
  actions: Actions(["sqs:SendMessage"]),
  resources: Resource(queueArn),
  conditions: {
    stringEquals: [("aws:SourceAccount", ConditionValue(accountId))]->Dict.fromArray,
    arnLike: [
      ("aws:SourceArn", ConditionValue(`arn:aws:events:*:${accountId}:rule/*`)),
    ]->Dict.fromArray,
  },
}
```

`accountId` is already in scope in the sibling helper via
`queueArn->String.split(":")->Array.get(4)`; lift that derivation rather than
re-implementing it. The hardcoded `"events.amazonaws.com"` string should become
`AWS.CloudwatchEventRule.principal` ([`AWS.res:45`](../../reventless/aws/src/adapter/AWS.res#L45))
in the same edit — the literal duplicates a value the module already owns.

`SourceAccount` alone closes the cross-account hole; the `ArnLike` narrows the
in-account surface to EventBridge rules specifically.

**Decision (both conditions shipped).** The plan flagged the `ArnLike` as
possibly too brittle — a move to EventBridge Scheduler (`arn:aws:scheduler:...`)
would stop matching it. That reasoning does not hold up: EventBridge Scheduler
sends under the `scheduler.amazonaws.com` principal, not
`events.amazonaws.com`, so such a migration fails this statement on the
principal before the ARN pattern is ever consulted and needs a new statement
regardless. The `ArnLike` therefore adds no brittleness the principal does not
already impose, and it is worth having.

## Steps

1. [x] Lift the `accountId` derivation and add the conditions in
   `CommandTopicChannel_Helpers.createQueuePolicy`; swap the literal principal
   for `AWS.CloudwatchEventRule.principal`.
   The derivation moved to `Adapter_Helpers.accountIdOfQueueArn` (both helper
   files already `open Adapter_Helpers`), and the policy body was extracted into
   a pure `createQueuePolicyDocument(~name, ~queueArn, ~lambdaArn) => string`
   mirroring `Util_DeadLetterQueue`'s — that is what makes step 2 testable.
   `"lambda.amazonaws.com"` became `AWS.Lambda.principal` in the same statement
   block for consistency.
2. [x] Build with zero warnings; check the rendered policy JSON in a unit test if
   a `PolicyDocument` assertion helper exists, otherwise assert via
   `pulumi preview --json` on the hybrid example.
   No helper existed; the extraction in step 1 made a direct unit test possible
   instead — `tests/CommandTopicQueuePolicyTest.res` parses the rendered JSON
   and asserts both condition keys, the service principal, and that the Lambda
   grant stays pinned to its function ARN. Mutation-checked: deleting the
   `SourceAccount` condition reds exactly one test.
3. [ ] **PENDING — requires a deploy.** Deploy to alpha and exercise the
   scheduler path end-to-end — create a schedule, confirm the runtime
   `PutTargets` succeeds and a message is delivered into the command topic
   queue. A wrong condition fails *closed* and silently: EventBridge accepts
   `PutTargets` and drops deliveries, so a deploy-time green is not sufficient
   evidence.
4. [x] Audit the remaining queue policies for the same omission.

## Audit results (step 4)

Seven service-principal statements exist under `reventless/aws/src`. Five were
already scoped, one is fixed here, and the audit surfaced two findings outside
this plan's scope:

| Statement | File | Status |
|---|---|---|
| `AllowCloudWatchEventsToSendToQueue` | `CommandTopicChannel_Helpers` | **Fixed here** |
| `AllowLambdaToAccessQueue` | `CommandTopicChannel_Helpers` | Scoped (`ArnEquals` function ARN) |
| `AllowLambdaToAccessQueue` | `Util_DeadLetterQueue` | Scoped (`ArnEquals` handler ARN) |
| `AllowReceiveSnsEvents` | `EventCollectorChannel_Helpers` | Scoped (`SourceAccount` + `ArnLike`) |
| `AllowSNSSend` | `EventLogSubscription_AppSync` | Scoped (`ArnEquals` topic ARN) |
| `AllowSES` | `Util_SesPolicy_Runtime` | **Finding A** |
| `AllowAppSyncInvoke` | `ClonerRunner_Fargate` | **Finding B** |

**Finding A — `Util_SesPolicy_Runtime.res:27`** grants `SES:SendEmail` /
`SES:SendRawEmail` on a verified identity to `Principal: {AWS: "*"}` with no
conditions — any AWS account, broader than the grant this plan closes. It is
currently **dead code**: `sesPolicyDocument` and `identityWithPolicy` have no
callers anywhere in `reventless/` or `examples/`. Not fixed here — the right
scoping depends on the intended caller, and inventing one would be guesswork.
Either delete the pair or condition it when a use case appears.

**Finding B — `ClonerRunner_Fargate.res:270`** builds an `AllowAppSyncInvoke`
statement *with* a `principal` field and merges it into `lambdaPolicyDocument`,
which is then attached via `IAM.RolePolicy`. IAM identity policies do not accept
`Principal` — only resource policies do. Either the merge drops it (making the
AppSync invoke grant silently absent) or AWS rejects the document. Unverified;
needs its own investigation, since it is a correctness question rather than a
scoping one.

## Validation

- [ ] Scheduled publish observed arriving in the command topic queue on alpha.
- [x] Rendered policy contains both condition keys — asserted in
  `tests/CommandTopicQueuePolicyTest.res`.
- [x] `grep` shows no remaining unconditioned *service*-principal statement in
  `reventless/aws/src` (see audit table; Finding A is an `AWS: "*"` principal,
  not a service principal, and is unreachable).
- [x] Conditions confirmed live on deployed infrastructure (see below).

## Deploy evidence (alpha, 2026-07-22)

Deployed via the `2f5f148f4` push; chain green end to end (CI → Release → Build
Lambda Layer → Deploy Online Shop Hybrid, run `29922990691`).

**No resource churn from the sibling dependency-edge change.** All three
affected policies updated in place — `~`, never `+-` — with `~policy` as the
only diff key, which is this plan's condition change:

```
~  aws:sqs:QueuePolicy PluginAggrCmdTopic              updating [diff: ~policy]
~  aws:sqs:QueuePolicy PlatformPluginExtPointCmdTopic  updating [diff: ~policy]
~  aws:sqs:QueuePolicy PlatformDcbCmdTopic             updating [diff: ~policy]

Resources: ~ 29 updated, 126 unchanged
```

**Conditions verified on the live queue**, read back from SQS rather than
inferred from the rendered document:

```json
"Sid": "AllowCloudWatchEventsToSendToQueue",
"Condition": {
  "StringEquals": { "aws:SourceAccount": "<account>" },
  "ArnLike":      { "aws:SourceArn": "arn:aws:events:*:<account>:rule/*" }
}
```

**The grant is confirmed load-bearing.** Runtime-created scheduler rules exist
on the account and their targets are command-topic queue ARNs directly
(`arn:aws:sqs:…:*PluginExtPointCmdTopic-*`), so the queue resource policy is
indeed the authorisation path — deleting the statement rather than scoping it
would have broken scheduled publishing.

**Why step 3 is still open.** The grant has not been exercised since the change.
Both disconnect rules created after the deploy report `Invocations: 0`
(`AWS/Events`, checked 14:07 UTC against a 13:16 UTC change), and the reason is
structural: a disconnect schedule is re-armed by every 5-minute heartbeat, so in
healthy operation it is *replaced before it fires*. The EventBridge→SQS path
only runs when a plugin actually goes silent past its grace window.

**How to close it.** `FailedInvocations` on the rule is the exact instrument —
EventBridge emits it when a target rejects delivery, which is precisely the
silent failure this plan worries about. Let one plugin's heartbeat lapse past
`disconnectGrace`, then check `Invocations` and `FailedInvocations` for its
disconnect rule: an invocation with zero failures is the proof. (This is also
the natural implementation of step 4 in the sibling plan.)

**Pre-existing failures, not caused by this change.** Account-wide
`FailedInvocations` over the preceding 24 h totalled 4, in two buckets at 10:00
and 12:00 UTC — both before the 13:16 UTC policy update. The likely cause is
rules still targeting `AdminEventColl` / `AdminDcbCmdTopic`, the queues
destroyed by the `Admin` → `Platform` rename. That connects the stale-rule
backlog to real failing deliveries rather than mere clutter; tracked in
[`Backlog/eventbridge-schedule-rule-accumulation.md`](Backlog/eventbridge-schedule-rule-accumulation.md).

## Risk

Low blast radius (one statement, one helper), but the failure mode is a silent
delivery drop rather than an error — hence the explicit end-to-end step 3. The
grant is currently over-broad, not broken, so there is no urgency to ship it
half-verified.
