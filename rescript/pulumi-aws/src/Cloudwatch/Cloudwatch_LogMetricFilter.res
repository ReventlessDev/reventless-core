/** @pulumi/aws/cloudwatch/logmetricfilter
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudwatch/logmetricfilter/
*/

/** How matched log events are turned into a CloudWatch metric data point.
  `value`/`dimensions` use metric-filter JSON selectors (e.g. `"$.value"`). */
type metricTransformation = {
  name: Pulumi.Input.t<string>,
  namespace: Pulumi.Input.t<string>,
  value: Pulumi.Input.t<string>,
  defaultValue?: Pulumi.Input.t<string>,
  unit?: Pulumi.Input.t<string>,
  dimensions?: Pulumi.Input.t<Dict.t<string>>,
}

type t = {id: Pulumi.Output.t<string>}

type args = {
  name?: Pulumi.Input.t<string>,
  /** Filter pattern matched against log events, e.g. `{ $.reventlessMetric = "AppendRetry" }`. */
  pattern: Pulumi.Input.t<string>,
  logGroupName: Pulumi.Input.t<string>,
  metricTransformation: Pulumi.Input.t<metricTransformation>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "LogMetricFilter"
