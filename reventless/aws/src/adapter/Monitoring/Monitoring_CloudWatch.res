// A CloudWatch alarm on every execution unit the framework provisions.
//
// Monitoring is deliberately not a framework concern — core announces a unit
// through the `Monitoring` seam and says nothing about what to do with it (see
// docs/plans/done/monitoring-hook-seam.md). This is one backend for that seam,
// living here rather than in core because it is provider-native to the bone:
// CloudWatch metrics, an SNS topic, an AWS notion of what "failing" means.
//
// It exists because the stacks this repo deploys itself had nothing attached, and
// those are the stacks where framework defects surface first — a wedged aggregate
// went unnoticed for twelve hours and was found by reading a bill. See
// docs/plans/no-monitoring-backend-on-deployed-stacks.md.
//
// A deploy program opts in with one line, before it builds its platform:
//
//     ReventlessAws.Monitoring_CloudWatch.use()
//
// and the deployment decides whether that line does anything:
//
//     alarmEmail                 ops@example.com   creates a topic + email subscription
//     alarmTopicArn              arn:aws:sns:...   publishes to a topic that exists
//     alarmSilenceWindowSeconds  3600              how long a scheduler may be quiet
//
// With neither address configured the backend provisions nothing at all, so a
// stack that has not opted in deploys byte-identical to one built without this
// module. That is what makes `use()` safe to commit unconditionally.
//
// Each key is read through `Util_LocalConfig` first — `REVENTLESS_ALARM_EMAIL` in
// CI, a gitignored `Pulumi.local.yaml` on a workstation — before the stack's own
// `platform:` config. Where alerts go is per-deployment and often personal, and a
// tracked `Pulumi.<stack>.yaml` in a public repository is the wrong place for
// somebody's inbox.
open PulumiAws

module M = ReventlessCore.Monitoring

// Local override first (env var, then the gitignored sidecar), then stack config.
let configured = (key: string): option<string> =>
  switch Util_LocalConfig.get(key) {
  | Some(_) as local => local
  | None => Pulumi.Config.make(Some("platform"))->Pulumi.Config.get(key)
  }

let configuredEmail = () => configured("alarmEmail")
let configuredTopicArn = () => configured("alarmTopicArn")

let silenceWindowSeconds = () =>
  configured("alarmSilenceWindowSeconds")
  ->Option.flatMap(Int.fromString(_))
  ->Option.getOr(Util_AlarmSpec.defaultSilenceWindowSeconds)

let topicName = "ReventlessAlarms"

// Resolved once, on the first alarm — so a stack that provisions no units, or one
// that has not configured an address, creates no topic either.
let resolvedTopic: ref<option<Pulumi.Output.t<string>>> = ref(None)

// An ARN the stack already owns wins over creating one: an estate with somewhere
// for alerts to go (a chat relay, a pager, one topic shared by several stacks)
// should point at it rather than accumulate a topic per stack that nobody reads.
let ensureTopicArn = (): option<Pulumi.Output.t<string>> =>
  switch resolvedTopic.contents {
  | Some(_) as resolved => resolved
  | None =>
    let resolved = switch (configuredTopicArn(), configuredEmail()) {
    | (Some(arn), _) => Some(arn->Pulumi.Output.make)
    | (None, Some(email)) =>
      let topic = SNS.Topic.make(
        ~name=topicName,
        ~args={
          SNS.Topic.tags: AWS.Tags.make(
            ~name=topicName,
            ~kind=ReventlessCore.ComponentType.Plugin,
            ~role=Other("Alarm"),
            ~scope=Plugin,
          ),
        },
      )
      let _subscription = SNS.TopicSubscription.make(
        ~name=topicName ++ "Email",
        ~args={
          endpoint: email->Pulumi.Input.make,
          topic: topic.arn->Pulumi.Output.asInput,
          protocol: Email,
        },
        ~opts=None,
      )
      Some(topic.arn)
    | (None, None) => None
    }
    resolvedTopic := resolved
    resolved
  }

let alarmFor = (
  ~spec: Util_AlarmSpec.t,
  ~kind: M.unitKind,
  ~name: string,
  ~component: ReventlessInfra.Adapter.resource,
  ~plugin: option<string>,
  ~platform: option<string>,
  ~logLocator: option<Pulumi.Output.t<string>>,
  ~topicArn: Pulumi.Output.t<string>,
) => {
  let resourceName = Util_AlarmSpec.resourceName(~kind, ~name, ~plugin, ~suffix=spec.suffix)
  let actions = [topicArn->Pulumi.Output.asInput]->Pulumi.Input.make

  // The description is the only field a state-change message carries, so it is
  // also where the log group goes — an alert names the unit and the metric and
  // never where to read what happened. `~logLocator` is an Output, so the whole
  // description resolves late; a unit with no logs of its own keeps a plain one.
  let describe = logs =>
    Util_AlarmSpec.description(~kind, ~name, ~plugin, ~platform, ~spec, ~logs)
  let alarmDescription = switch logLocator {
  | Some(locator) => locator->Pulumi.Output.map(g => describe(Some(g)))->Pulumi.Output.asInput
  | None => describe(None)->Pulumi.Input.make
  }

  Cloudwatch.MetricAlarm.make(
    ~name=resourceName,
    ~args={
      comparisonOperator: spec.comparisonOperator->Pulumi.Input.make,
      evaluationPeriods: spec.evaluationPeriods->Pulumi.Input.make,
      metricName: spec.metricName->Pulumi.Input.make,
      namespace: spec.namespace->Pulumi.Input.make,
      period: spec.period->Pulumi.Input.make,
      statistic: spec.statistic->Pulumi.Input.make,
      threshold: spec.threshold->Pulumi.Input.make,
      // Every unit this seam announces on AWS is a Lambda function, which is what
      // makes one dimension enough. A future non-Lambda execution unit needs the
      // namespace and dimension to come from the announcement rather than from here.
      dimensions: component.name
      ->Pulumi.Output.apply(fn => Dict.fromArray([("FunctionName", fn)]))
      ->Pulumi.Output.asInput,
      treatMissingData: spec.treatMissingData->Pulumi.Input.make,
      alarmActions: actions,
      // Without these the channel reports every incident and no recovery, and a
      // reader cannot tell an ongoing outage from one that cleared minutes later.
      okActions: actions,
      alarmDescription,
      tags: AWS.Tags.make(
        ~name=resourceName,
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Other("Alarm"),
        ~component=name,
        ~plugin?,
        ~platform?,
      ),
    },
  )
}

module Backend: M.Backend = {
  let onProvisioned = (~kind, ~name, ~component, ~plugin, ~platform, ~logLocator) =>
    switch ensureTopicArn() {
    | None => ()
    | Some(topicArn) =>
      Util_AlarmSpec.forKind(~kind, ~silenceWindowSeconds=silenceWindowSeconds())->Array.forEach(
        spec => {
          let _alarm = alarmFor(
            ~spec,
            ~kind,
            ~name,
            ~component,
            ~plugin,
            ~platform,
            ~logLocator,
            ~topicArn,
          )
        },
      )
    }
}

/** Register this backend. Call it before building the platform — announcements
    made earlier still arrive, because the seam holds them until someone
    registers, but resources this creates must belong to the deploy program's own
    run. Safe on a stack that configures no address: it provisions nothing. */
let use = () => M.use(module(Backend: M.Backend))
