open JestGlobals

let field = (json: JSON.t, key: string): option<JSON.t> =>
  switch json {
  | JSON.Object(dict) => dict->Dict.get(key)
  | _ => None
  }

let str = json => json->Option.flatMap(JSON.Decode.string)
let num = json => json->Option.flatMap(JSON.Decode.float)

describe("Metrics.metricLine", () => {
  let line = Metrics.metricLine(~metric="AppendConflict", ~slice="AddItem")

  testSync("is a provider-neutral line — no AWS/CloudWatch vocabulary", () => {
    // Guards the layering: core must not emit `_aws` / EMF.
    expect(line->field("_aws"))->toEqual(None)
    expect(line->field("CloudWatchMetrics"))->toEqual(None)
  })

  testSync("carries the metric discriminator and name", () => {
    expect(line->field(Metrics.discriminator)->str)->toEqual(Some("AppendConflict"))
  })

  testSync("carries the slice dimension and a default count of 1", () => {
    expect(line->field("slice")->str)->toEqual(Some("AddItem"))
    expect(line->field("value")->num)->toEqual(Some(1.0))
    expect(line->field("unit")->str)->toEqual(Some("Count"))
  })

  testSync("honours an explicit count value", () => {
    let l = Metrics.metricLine(~metric="AppendRetry", ~slice="S", ~value=3)
    expect(l->field("value")->num)->toEqual(Some(3.0))
    expect(l->field(Metrics.discriminator)->str)->toEqual(Some("AppendRetry"))
  })
})
