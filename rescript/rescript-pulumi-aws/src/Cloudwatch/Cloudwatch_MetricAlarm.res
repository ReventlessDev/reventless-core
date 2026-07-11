/** @pulumi/aws/cloudwatch/metricalarm
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudwatch/metricalarm/
*/

type t = {arn: Pulumi.Output.t<string>, id: Pulumi.Output.t<string>}

/** Single-metric alarm args. `comparisonOperator` uses CloudWatch's operator
  names (e.g. `"GreaterThanOrEqualToThreshold"`); `statistic` is `"Sum"`,
  `"Average"`, … ; `treatMissingData` is `"missing"`, `"notBreaching"`,
  `"breaching"`, or `"ignore"`; `alarmActions` are ARNs (typically an SNS topic)
  fired when the alarm enters ALARM state. */
type args = {
  name?: Pulumi.Input.t<string>,
  comparisonOperator: Pulumi.Input.t<string>,
  evaluationPeriods: Pulumi.Input.t<int>,
  metricName: Pulumi.Input.t<string>,
  namespace: Pulumi.Input.t<string>,
  /** Metric period in seconds. */
  period: Pulumi.Input.t<int>,
  statistic: Pulumi.Input.t<string>,
  threshold: Pulumi.Input.t<float>,
  /** Metric dimensions, e.g. `{"FunctionName": "AllAggregatesCmdHandler"}`. */
  dimensions?: Pulumi.Input.t<Dict.t<string>>,
  treatMissingData?: Pulumi.Input.t<string>,
  alarmActions?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  alarmDescription?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "MetricAlarm"
