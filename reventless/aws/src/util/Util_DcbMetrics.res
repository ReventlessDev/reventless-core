// The CloudWatch half of DCB metrics: the provider-neutral metric lines that
// StateChangeSlice_Callback emits (`{reventlessMetric, slice, value}`) become
// CloudWatch metrics through a log metric filter per metric name. Namespace and
// dimension are CloudWatch-specific and belong here rather than in core.
//
// Pure on purpose. The filters are only built for a Lambda that has a MANAGED log
// group to attach to, so no stack exercised this code until managed groups existed
// — and an invalid transformation therefore shipped without any deploy catching it.
// Keeping the transformation a plain function makes the one rule CloudWatch enforces
// testable without standing up a Pulumi resource.

open PulumiAws

/** The metrics extracted from a DCB command handler's logs. */
let metricNames = [
  "AppendRetry",
  "AppendConflict",
  "DcbDecisionModelCacheHit",
  "DcbDecisionModelCacheMiss",
  "DcbDecisionModelDeltaEventCount",
]

let namespace = "Reventless/DCB"

/** Filter pattern selecting one metric's lines out of the log stream. */
let patternFor = (metricName: string): string => `{ $.reventlessMetric = "${metricName}" }`

/**
The metric transformation for one DCB metric, dimensioned by slice.

`dimensions` and `defaultValue` are **mutually exclusive** — `PutMetricFilter`
rejects a transformation carrying both with `InvalidParameterException: Invalid
metric transformation: dimensions and default value are mutually exclusive
properties`. The reason is that a default value is emitted when the pattern does not
match, and for a dimensioned metric there is no dimension value to attribute such a
point to.

The `slice` dimension is the half worth keeping: without it every slice's counts
collapse into one undifferentiated series. So this sets no `defaultValue`, and a
metric simply reports no data point for a period in which nothing matched.
*/
let transformationFor = (metricName: string): Cloudwatch.LogMetricFilter.metricTransformation => {
  name: metricName->Pulumi.Input.make,
  namespace: namespace->Pulumi.Input.make,
  value: "$.value"->Pulumi.Input.make,
  unit: "Count"->Pulumi.Input.make,
  dimensions: Dict.fromArray([("slice", "$.slice")])->Pulumi.Input.make,
}
