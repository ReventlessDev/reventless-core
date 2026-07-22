# Plan: Scope the CommandTopic Queue Policy's EventBridge Send Grant

**Discovered**: 2026-07-22, while tracing the SQS `QueuePolicy` destroy race
(orphaned `AdminEventColl` / `AdminDcbCmdTopic` policy deletes after the
`Admin*` -> `Platform*` rename).

**Sibling item**: the dependency-edge fix for the same five `QueuePolicy` call
sites (resources constructed inside `Pulumi.Output.apply`, `queueUrl` passed as
an unwrapped string). Independent of this plan — that one is about destroy
ordering, this one is about the policy's contents.

## Problem

[`CommandTopicChannel_Helpers.res:34-42`](../../../reventless/aws/src/adapter/CommandTopic/CommandTopicChannel_Helpers.res#L34-L42)
attaches an unconditioned service-principal grant to every CommandTopic queue:

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
([`PolicyDocument.res:114`](../../../rescript/pulumi-aws/src/IAM/PolicyDocument.res#L114)),
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
[`ScheduledPublisher_CloudWatchEvents_Runtime.res:38-60`](../../../reventless/aws/src/adapter/ScheduledPublisher/ScheduledPublisher_CloudWatchEvents_Runtime.res#L38-L60)
issues `PutRuleCommand` + `PutTargetsCommand` with `arn: resource.urn` over the
queue resources handed to it. For SQS targets EventBridge authorises against the
queue's resource policy, so removing the statement breaks scheduled publishing.

(The heartbeat path is unaffected either way — its EventBridge rule targets a
Lambda, which then sends to the queue under its own execution role. See
[`HeartbeatRunner_CloudWatchEvents.res:86-96`](../../../reventless/aws/src/plugin/heartbeat/HeartbeatRunner_CloudWatchEvents.res#L86-L96).)

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
  in [`aws-adapters-critical-fixes.md`](aws-adapters-critical-fixes.md) as a
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
`AWS.CloudwatchEventRule.principal` ([`AWS.res:45`](../../../reventless/aws/src/adapter/AWS.res#L45))
in the same edit — the literal duplicates a value the module already owns.

`SourceAccount` alone closes the cross-account hole; the `ArnLike` narrows the
in-account surface to EventBridge rules specifically. Consider whether the
`arnLike` is worth the brittleness — if a future scheduler variant uses
EventBridge Scheduler (`arn:aws:scheduler:...`) rather than Events, the pattern
would silently stop matching. `SourceAccount`-only is the conservative floor.

## Steps

1. Lift the `accountId` derivation and add the conditions in
   `CommandTopicChannel_Helpers.createQueuePolicy`; swap the literal principal
   for `AWS.CloudwatchEventRule.principal`.
2. Build with zero warnings; check the rendered policy JSON in a unit test if a
   `PolicyDocument` assertion helper exists, otherwise assert via
   `pulumi preview --json` on the hybrid example.
3. Deploy to alpha and exercise the scheduler path end-to-end — create a
   schedule, confirm the runtime `PutTargets` succeeds and a message is
   delivered into the command topic queue. A wrong condition fails *closed* and
   silently: EventBridge accepts `PutTargets` and drops deliveries, so a
   deploy-time green is not sufficient evidence.
4. Audit the remaining queue policies for the same omission when the
   dependency-edge fix touches them.

## Validation

- Scheduled publish observed arriving in the command topic queue on alpha.
- Rendered policy contains both condition keys.
- `grep` shows no remaining unconditioned service-principal statement in
  `reventless/aws/src`.

## Risk

Low blast radius (one statement, one helper), but the failure mode is a silent
delivery drop rather than an error — hence the explicit end-to-end step 3. The
grant is currently over-broad, not broken, so there is no urgency to ship it
half-verified.
