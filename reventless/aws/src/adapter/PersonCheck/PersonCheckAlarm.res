// The deploy side of a person check that cannot be asked: where the plugin has a
// door that starts a sign-up, its command function's logs are read for the
// metric line `AwsPersonCheck` writes, and an alarm tells the operator, since
// every visitor is being turned away.

let alarmPeriodSeconds = 300

/** The alarm, once per plugin stack. */
let make = () =>
  if PersonCheckMetric.current() {
    let alerts = PluginRuntime_Builder.operatorAlerts()
    let _ = PulumiAws.Cloudwatch.MetricAlarm.make(
      ~name="PersonCheckUnavailable",
      ~args={
        comparisonOperator: "GreaterThanThreshold"->Pulumi.Input.make,
        evaluationPeriods: 1->Pulumi.Input.make,
        metricName: AwsPersonCheck.metricName->Pulumi.Input.make,
        namespace: Util_DcbMetrics.namespace->Pulumi.Input.make,
        period: alarmPeriodSeconds->Pulumi.Input.make,
        statistic: "Sum"->Pulumi.Input.make,
        threshold: 0.->Pulumi.Input.make,
        dimensions: Dict.fromArray([("slice", AwsPersonCheck.metricSlice)])->Pulumi.Input.make,
        treatMissingData: "notBreaching"->Pulumi.Input.make,
        alarmActions: alerts
        ->Pulumi.Output.apply(arn => arn == "" ? [] : [arn->Pulumi.Input.make])
        ->Pulumi.Output.asInput,
        alarmDescription: (`The check that a person is signing up cannot be asked, so every ` ++
        `sign-up is refused. Its provider is down, its secret is wrong, or the function has ` ++ `no route to it.`)
          ->Pulumi.Input.make,
        tags: AWS.Tags.make(
          ~name="PersonCheckUnavailable",
          ~kind=ReventlessCore.ComponentType.Plugin,
          ~role=Other("Alarm"),
          ~component="PersonCheck",
        ),
      },
    )
  }
