---
title: Operating a deployment
sidebar_label: Operating a deployment
---

# Operating a deployment

What a Reventless deployment costs, where to look when something is wrong, and
what the deploying principal needs to be allowed to do.

## What it costs

Every resource the AWS provider creates is pay-per-request and scales to zero:
DynamoDB on-demand tables, Lambda functions, SQS queues, SNS topics, an AppSync
API, S3 buckets, a CloudFront distribution, and a Cognito user pool. Nothing is
always-on, so an idle deployment costs approximately nothing — which is what
makes one deployment per environment, or per pull request, practical.

The costs that do accrue when nothing is happening:

| What | Why it costs at rest |
|---|---|
| Stored events and read model rows | Storage is per GB-month, and the event log only grows — it is the record. |
| Objects in the stores your `@storageRef` / `@offload` fields use | Same, plus request costs when served. |
| CloudWatch log retention | Tiered per stack; a long-retention production stack keeps a year of logs. |
| A custom domain | The hosted zone, if you add one. Not created by default. |

The costs that scale with traffic are per request across the board: a command is
one API call plus a function invocation plus a write; a query is one API call
plus a read. There is no per-connection charge to keep a live subscription open.

Two things would change the shape of this, both deliberate choices you make:
putting a storage surface on [Postgres](./postgres-status.md) buys exact append
semantics and costs an always-on instance, and running heavy read models on
provisioned rather than on-demand capacity trades scale-to-zero for a lower
per-request price.

## Log retention and levels

Retention and log level are tiered by stack, not fixed — production is quiet and
kept for a long time, development stacks are loud and expire quickly. See
[Lambda deployment](./lambda-deployment.md) for the tier table and how the log
group is named.

`LOG_LEVEL` is only an environment variable, so raising it on a misbehaving
component is a deploy, not a migration.

## When a message cannot be processed

Every queue redrives to a dead-letter queue after its retries are exhausted —
one standard and one FIFO, both retaining messages for the SQS maximum of 14
days. That maximum is chosen rather than inherited: a dead letter is the only
surviving evidence of a message the system could not process, and the four-day
default can expire it over a long weekend.

**A dead letter raises an alarm by failing.** The handler attached to the
dead-letter queue logs the payload and then throws. That is deliberate: a handler
that swallowed the message would delete it from the queue and leave the
function's error metric at zero, so neither the queue depth nor the error count
would signal anything. Failing instead keeps the message on the queue until
retention expires and keeps the error metric non-zero for as long as the
condition lasts — both conventional alarm subjects.

### What to watch

| Signal | What it means |
|---|---|
| Dead-letter queue depth above zero | Something failed past its retries. On a queue that is empty in normal operation, any depth is the alert. |
| Errors on the dead-letter handler | The same condition, expressed as a metric you can alarm on directly. |
| `DEAD LETTER ITEM:` in the logs | The full payload of each dead-lettered message, re-logged on every redelivery. |
| Command handler errors | Failures before the retries ran out — the earlier warning. |
| Rising conditional-append conflicts | Contention on a hot tag; usually a boundary drawn too wide rather than a fault. |

### Inspecting and redriving

Read the payloads without consuming them:

```bash
aws sqs receive-message \
  --queue-url <dlq-url> \
  --max-number-of-messages 10 \
  --visibility-timeout 0
```

Once the cause is fixed, AWS's queue redrive moves the messages back to their
source queue for reprocessing:

```bash
aws sqs start-message-move-task \
  --source-arn <dlq-arn> \
  --destination-arn <source-queue-arn>
```

Redrive only makes sense once the failure is actually fixed — otherwise the
messages take one more lap and come back. And because command handlers are
idempotent by design, a message that half-succeeded before failing is safe to
replay; that property is what makes redrive an ordinary operation rather than a
gamble.

## What the deploying principal needs

A deploy creates and updates the whole application stack, so its credentials are
broad by nature. Two rules keep that from becoming worse than it has to be:

**Separate the roles that do different jobs.** The credentials that publish the
Lambda layer need only to publish and read versions of that one layer and write
the parameter holding its ARN. The credentials that deploy a stack need to read
that parameter and nothing else about layers. Neither should be able to do the
other's job.

**Scope per environment.** A principal that can deploy the development stack has
no reason to be able to touch production. Separate accounts are the cleanest
version of this; separate roles with distinct resource prefixes are the
practical one.

The services a deploying principal must reach: DynamoDB, Lambda, SQS, SNS, S3,
AppSync, CloudFront, Cognito, EventBridge, CloudWatch Logs, IAM (to create the
execution roles the components run under), and SSM if you keep the layer ARN
there.

:::caution The EventBridge permissions are broader than they look
Heartbeats and scheduled publishing create EventBridge rules and targets, and
the rule APIs do not scope down as neatly as most. Grant them deliberately
rather than as part of a wildcard, and expect to revisit this if you tighten the
policy later.
:::

## Tearing down

The two things that block a destroy are protected object stores and non-empty
buckets, both on purpose. The
[teardown steps](/tutorials/deploy-to-aws#tearing-it-down-again) walk through
both, plus the leftovers worth checking for afterwards.
