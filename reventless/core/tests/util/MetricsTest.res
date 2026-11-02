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

describe("Metrics.Sink", () => {
  afterEach(() => Metrics.Sink.reset())

  testSync("emitCount hands each occurrence to the installed sink", () => {
    let seen = []
    Metrics.Sink.install(s => seen->Array.push(s))
    Metrics.emitCount(~metric="AppendRetry", ~slice="PlaceOrder")
    Metrics.emitCount(~metric="DcbDecisionModelDeltaEventCount", ~slice="PlaceOrder", ~value=4)
    expect(seen->Array.map(s => (s.metric, s.slice, s.value)))->toEqual([
      ("AppendRetry", "PlaceOrder", 1),
      ("DcbDecisionModelDeltaEventCount", "PlaceOrder", 4),
    ])
  })
})

describe("Metrics.Counts", () => {
  let minute = 60_000.
  let at0 = 1_800_000_000_000.
  let sample = (~metric="AppendRetry", ~slice="PlaceOrder", ~value=1, ~at): Metrics.sample => {
    metric,
    slice,
    plugin: "Ordering",
    value,
    unit: "Count",
    at,
  }

  testSync("counts by metric and slice, and sums the values", () => {
    let t = Metrics.Counts.make()
    t->Metrics.Counts.add(sample(~at=at0))
    t->Metrics.Counts.add(sample(~at=at0 +. 1000.))
    t->Metrics.Counts.add(sample(~metric="DcbDecisionModelDeltaEventCount", ~value=3, ~at=at0))
    t->Metrics.Counts.add(sample(~metric="DcbDecisionModelDeltaEventCount", ~value=5, ~at=at0))
    t->Metrics.Counts.add(sample(~slice="AddProduct", ~at=at0))
    let read = t->Metrics.Counts.read(~now=at0 +. 1000.)
    expect(read->Array.map(s => (s.slice, s.metric, s.count, s.sum)))->toEqual([
      ("AddProduct", "AppendRetry", 1, 1.),
      ("PlaceOrder", "AppendRetry", 2, 2.),
      ("PlaceOrder", "DcbDecisionModelDeltaEventCount", 2, 8.),
    ])
  })

  testSync("keeps the last 60 minutes, one bucket a minute, moving on as time passes", () => {
    let t = Metrics.Counts.make()
    t->Metrics.Counts.add(sample(~at=at0))
    t->Metrics.Counts.add(sample(~at=at0 +. 2. *. minute))
    t->Metrics.Counts.add(sample(~at=at0 +. 2. *. minute +. 10.))
    let perMinute = now => (t->Metrics.Counts.read(~now)->Array.getUnsafe(0)).perMinute
    let now = at0 +. 2. *. minute
    expect(perMinute(now)->Array.slice(~start=57, ~end=60))->toEqual([1, 0, 2])
    // Three minutes later the counts have moved three buckets back.
    expect(perMinute(now +. 3. *. minute)->Array.slice(~start=54, ~end=60))->toEqual([
      1,
      0,
      2,
      0,
      0,
      0,
    ])
    // After an hour without counts every bucket is zero, and the total stays.
    expect(perMinute(now +. 61. *. minute)->Array.every(n => n == 0))->toBe(true)
    expect((t->Metrics.Counts.read(~now)->Array.getUnsafe(0)).count)->toBe(3)
  })

  testSync("is narrowed by plugin", () => {
    let t = Metrics.Counts.make()
    t->Metrics.Counts.add(sample(~at=at0))
    t->Metrics.Counts.add({...sample(~at=at0), plugin: "Catalog"})
    expect(t->Metrics.Counts.read(~now=at0, ~plugins=["Catalog"])->Array.length)->toBe(1)
  })
})
