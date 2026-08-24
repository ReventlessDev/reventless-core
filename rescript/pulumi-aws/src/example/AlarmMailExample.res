// Compile-only smoke for the EventBridge bindings: a rule that matches CloudWatch
// alarm state changes by pattern, and an SNS target that rewrites the matched event
// into a plain-text body rather than forwarding the raw JSON. Not executed at deploy
// time — it keeps `eventPattern` and `inputTransformer` type-checked together.

let alarmMailTopic = SNS.Topic.make(~name="example-alarm-mail")

let alarmStateChanges = Cloudwatch.EventRule.make(
  ~name="example-alarm-state-changes",
  ~args={
    description: "CloudWatch alarm state changes, ALARM and OK only"->Pulumi.Input.make,
    eventPattern: `{"source":["aws.cloudwatch"],"detail-type":["CloudWatch Alarm State Change"],"detail":{"state":{"value":["ALARM","OK"]}}}`->Pulumi.Input.make,
  },
)

// A template that is not JSON has to arrive quoted — the surrounding double quotes are
// part of the value, not ReScript syntax.
let mailBody: Cloudwatch.EventTarget.inputTransformer = {
  inputPaths: Dict.fromArray([
    ("name", "$.detail.alarmName"),
    ("state", "$.detail.state.value"),
    ("reason", "$.detail.state.reason"),
  ]),
  inputTemplate: `"<state>: <name> — <reason>"`->Pulumi.Input.make,
}

let _ = Cloudwatch.EventTarget.make(
  ~name="example-alarm-mail-target",
  ~args={
    rule: Cloudwatch.EventTarget.Rule.ofEventRule(alarmStateChanges),
    arn: alarmMailTopic.arn->Pulumi.Output.asInput,
    inputTransformer: mailBody->Pulumi.Input.make,
  },
)
