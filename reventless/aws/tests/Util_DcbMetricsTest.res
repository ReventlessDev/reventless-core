open JestGlobals

// The rule that matters is CloudWatch's, not ours: a metric transformation may carry
// `dimensions` OR `defaultValue`, never both. Violating it is not caught at compile
// time — both fields are optional in the binding — and not caught at deploy time
// either unless the stack happens to have a managed log group for the filter to
// attach to. So it is asserted here.

describe("Util_DcbMetrics.transformationFor", () => {
  testSync("never sets defaultValue — it is mutually exclusive with dimensions", () =>
    Util_DcbMetrics.metricNames->Array.forEach(m =>
      expect(Util_DcbMetrics.transformationFor(m).defaultValue)->toBe(None)
    )
  )

  testSync("dimensions the metric by slice", () =>
    expect(
      Util_DcbMetrics.transformationFor("AppendRetry").dimensions->Option.isSome,
    )->toBe(true)
  )

  testSync("counts into the DCB namespace", () =>
    expect(Util_DcbMetrics.transformationFor("AppendRetry").namespace)->toBe("Reventless/DCB")
  )

  testSync("names the metric after the emitted marker", () =>
    expect(Util_DcbMetrics.transformationFor("AppendConflict").name)->toBe("AppendConflict")
  )
})

describe("Util_DcbMetrics.patternFor", () => {
  testSync("selects one metric's lines by its marker", () =>
    expect(Util_DcbMetrics.patternFor("AppendRetry"))->toBe(`{ $.reventlessMetric = "AppendRetry" }`)
  )
})
