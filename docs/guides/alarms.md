# Alarms on a deployed stack

Reventless announces every **execution unit** it provisions — command handlers,
projections, reactors, event collectors, tasks, the scheduler, the dead-letter
sink — through the `Monitoring` seam. Monitoring itself is not a framework
concern: core says *"I provisioned a unit of this kind"* and a registered backend
decides what to do about it.

`Monitoring_CloudWatch` is one such backend, shipped in `reventless-aws`. It puts
a CloudWatch alarm on every announced unit and points them all at one SNS topic.

## Turning it on

One line in the deploy program, **before** the platform is built:

```rescript
ReventlessAws.Monitoring_CloudWatch.use()
```

and somewhere for alerts to go:

| Key | Meaning |
|-----|---------|
| `alarmEmail` | Creates a topic and subscribes this address to it |
| `alarmTopicArn` | Publishes to a topic that already exists; wins over `alarmEmail` |
| `alarmSilenceWindowSeconds` | How long a scheduler may be quiet before that is the fault (default `3600`) |

Each is read from `REVENTLESS_ALARM_EMAIL` (etc.) first, then a gitignored
`Pulumi.local.yaml`, then the stack's `platform:` config — the layering
[`Util_LocalConfig`](../../reventless/aws/src/util/Util_LocalConfig.res) provides
everywhere. Where an alert goes is per-deployment and usually somebody's inbox,
so prefer the environment variable in CI and the sidecar on a workstation over a
tracked `Pulumi.<stack>.yaml`.

**With neither address set, `use()` provisions nothing.** A stack that has not
opted in deploys byte-identical to one built without the module, which is what
makes the call safe to commit unconditionally: switching an estate's monitoring on
becomes a config key rather than a code change somebody has to remember.

An `alarmEmail` subscription is *pending* until the recipient follows the
confirmation link AWS sends. Until then the alarms exist and mail nobody.

## What you get

One alarm per unit, `Errors >= 1` over 5 minutes, with two exceptions that matter
more than the rule.

**A dead-letter sink alarms on `Invocations`, not `Errors`.** That handler fails
on every delivery by design — failing is how it keeps the message and keeps the
`Errors` metric non-zero — so `Errors` says only that it is doing its job. That it
ran *at all* is the incident.

Do not be tempted to alarm a dead-letter queue on **depth** instead. A consumer
that keeps failing keeps its messages *in flight*, so
`ApproximateNumberOfMessagesVisible` reads zero throughout: on the incident that
prompted this guide the queue held seven messages and reported `0 visible, 7 not
visible` for twelve hours.

**A scheduler gets two alarms**, and the second is the one that catches the
interesting failure. A heartbeat that *stops* emits no errors and no invocations,
so there is nothing for an `Errors` alarm to see — the absence is the fault. The
silence alarm inverts the test (`Invocations < 1` over `alarmSilenceWindowSeconds`)
and treats missing data as **breaching**, the only combination that fires on a
metric that has stopped being published. The default hour is twelve missed beats
at the default 5-minute `heartbeatInterval`; raise it if a plugin heartbeats less
often.

Every other kind gets the plain `Errors` alarm, with missing data treated as
*not* breaching — an idle stack publishes no datapoints, and a stack permanently
in alarm teaches everyone to ignore it.

## What the notification says

A CloudWatch state-change message carries the alarm's **description** and neither
its tags nor its name, so the description holds everything a reader or a parser
needs:

```
Reventless: scheduler 'CatalogPluginHeartbeat' (plugin Catalog, platform online-shop)
has not run for 60 minutes. Logs: /aws/lambda/online-shop-CatalogPluginHeartbeat.
[reventless plugin=Catalog platform=online-shop component=CatalogPluginHeartbeat kind=scheduler]
```

The log group comes from the seam's `~logLocator`: an alert names the unit and the
metric but never *where to read what happened*, and a backend cannot derive the
address — whether a unit's logs live in a managed group or the one Lambda
auto-creates is stack configuration the runtime resolved and did not record.

Platform substrate owned by no plugin — a dead-letter queue is shared by every
plugin in the estate — says neither, rather than naming one plugin and being
wrong.

## What it costs

Alarms are billed per alarm per month; a small estate provisions on the order of
twenty to thirty. The alarms publish only on a state change, so an estate that is
healthy costs the alarms and nothing else. Pointing several stacks at one existing
topic with `alarmTopicArn` avoids a topic and subscription per stack.

## Verifying

Not "the alarms exist" — a test asserts that. Break something on a disposable
stack and measure the time to a notification: a handler that throws on every
message should produce mail within about five minutes.

Worth checking permanently: **the number of alarms in a stack should equal the
number of execution units it provisions.** A unit provisioned without one is the
silent case returning, and that check would have caught the dead-letter sink
missing its alarm for as long as the seam had existed.
