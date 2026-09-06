// What to alarm on, per kind of execution unit — the pure half of the CloudWatch
// monitoring backend. `Monitoring_CloudWatch` turns these into resources; every
// decision worth arguing with is here, where a test can reach it without
// importing @pulumi/pulumi. Same split as Util_LogRetention / Util_LambdaLogging.

module M = ReventlessCore.Monitoring

/** One alarm. `suffix` distinguishes several alarms on one unit; the empty
    string is the unit's primary alarm. */
type t = {
  metricName: string,
  namespace: string,
  /** CloudWatch operator name, e.g. `"GreaterThanOrEqualToThreshold"`. */
  comparisonOperator: string,
  threshold: float,
  /** Seconds. */
  period: int,
  evaluationPeriods: int,
  statistic: string,
  /** `"missing"` | `"notBreaching"` | `"breaching"` | `"ignore"`. */
  treatMissingData: string,
  suffix: string,
  /** One clause, for the description a person reads in the notification. */
  meaning: string,
}

/** How long a scheduled unit may produce no invocation before that silence is
    itself the fault. The default is an hour: the plugin heartbeat's default
    interval is 5 minutes, so an hour is twelve missed beats — far enough out that
    a slow deploy or a throttle cannot trip it, close enough that a stopped
    scheduler is caught within the hour rather than by its consequences days
    later. Deployments that set a long `heartbeatInterval` should raise it. */
let defaultSilenceWindowSeconds = 60 * 60

let errorsAlarm = {
  metricName: "Errors",
  namespace: "AWS/Lambda",
  comparisonOperator: "GreaterThanOrEqualToThreshold",
  threshold: 1.0,
  period: 300,
  evaluationPeriods: 1,
  statistic: "Sum",
  // A unit that is not running produces no datapoints, and "no traffic" is not a
  // failure — an idle stack must not sit permanently in alarm, or every alarm it
  // raises is discounted.
  treatMissingData: "notBreaching",
  suffix: "",
  meaning: "is failing on its messages (Errors >= 1 in 5min)",
}

/**
The alarms for one kind of execution unit. More than one is allowed, because for
some kinds a single metric cannot express the fault.

- **Dead-letter sink** — the metric is `Invocations`, not `Errors`. This handler
  fails on every delivery by design, so `Errors` says only that it is doing its
  job; that it ran at all is the incident.
- **Scheduler** — two alarms, and the second is the one that matters. A heartbeat
  that *stops* emits no errors and no invocations, so the absence is the fault and
  `Errors` cannot see it. The silence alarm inverts the test (`Invocations < 1`)
  and treats missing data as breaching, which is the only combination that fires
  on a metric that has stopped being published. This is the exact shape that went
  unnoticed on a deployed estate: plugins stopped heartbeating and nothing said so.
- **Everything else** — `Errors >= 1`.
*/
let forKind = (~kind: M.unitKind, ~silenceWindowSeconds=defaultSilenceWindowSeconds): array<t> =>
  switch kind {
  | DeadLetterSink => [
      {
        ...errorsAlarm,
        metricName: "Invocations",
        meaning: "received a dead letter (an invocation here IS the incident)",
      },
    ]
  | Scheduler => [
      errorsAlarm,
      {
        ...errorsAlarm,
        metricName: "Invocations",
        comparisonOperator: "LessThanThreshold",
        period: silenceWindowSeconds,
        // The point of the alarm: a metric that stopped being published is the
        // failure, so its absence must breach rather than be excused.
        treatMissingData: "breaching",
        suffix: "Silent",
        meaning: "has not run for " ++ (silenceWindowSeconds / 60)->Int.toString ++ " minutes",
      },
    ]
  | _ => [errorsAlarm]
  }

/** Lower-case, hyphen-free rendering of a kind, for a resource name and for the
    machine-readable `kind=` in a description. `Other` carries its own word. */
let kindSlug = (kind: M.unitKind): string =>
  switch kind {
  | CommandHandler => "commandhandler"
  | Projection => "projection"
  | Reactor => "reactor"
  | EventCollector => "eventcollector"
  | Task => "task"
  | Scheduler => "scheduler"
  | DeadLetterSink => "deadlettersink"
  | Other(word) => "other" ++ word->String.toLowerCase
  }

/**
The alarm's logical (Pulumi) resource name.

Carries the plugin when there is one: `~name` is the component only, and two
plugins in a platform can own like-named components — a collision here is a
Pulumi duplicate-resource failure at deploy time, not a subtle one, but the fix
belongs in the name rather than in the reader's memory.
*/
let resourceName = (~kind: M.unitKind, ~name: string, ~plugin: option<string>, ~suffix: string) => {
  let owner = switch plugin {
  | Some(p) => p ++ "-"
  | None => ""
  }
  `alarm-${kind->kindSlug}-${owner}${name}${suffix}`
}

/**
What the notification says.

Two audiences in one string, because a CloudWatch state-change message carries the
description and neither the alarm's tags nor its name: a sentence for the person
who reads the mail, and a bracketed token for anything parsing it. Without the
platform the mail cannot say which estate fired — one platform runs many plugins
whose components are named by role, so `CatalogPluginHeartbeat` alone is ambiguous
across stacks.
*/
let description = (
  ~kind: M.unitKind,
  ~name: string,
  ~plugin: option<string>,
  ~platform: option<string>,
  ~spec: t,
  ~logs: option<string>,
) => {
  let owner = switch (plugin, platform) {
  | (Some(p), Some(pl)) => ` (plugin ${p}, platform ${pl})`
  | (Some(p), None) => ` (plugin ${p})`
  | (None, Some(pl)) => ` (platform ${pl})`
  // Platform substrate, owned by no plugin — a dead-letter queue is shared by
  // every plugin in the estate, so naming one would be a lie.
  | (None, None) => ""
  }
  let logsClause = switch logs {
  | Some(group) => ` Logs: ${group}.`
  | None => ""
  }
  `Reventless: ${kind->kindSlug} '${name}'${owner} ${spec.meaning}.${logsClause}` ++
  ` [reventless plugin=${plugin->Option.getOr("")} platform=${platform->Option.getOr("")}` ++
  ` component=${name} kind=${kind->kindSlug}]`
}
