// Unit tests for DomainDeadCode.analyze — orphan-event reachability over synthetic
// pluginStructures. Pure (no reventless-local import), so it runs under Jest. The
// real end-to-end pass over the example plugins is exercised by the LocalHost
// integration test; here we drive the analysis with hand-built fixtures to pin the
// orphan / not-orphan boundary precisely.

open AsyncTest
open AsyncTest.Expect

// ── terse builders for the verbose pluginStructure sub-records ──
let writable = (~name, ~produces=[], ~consumes=[], ~linkedViews=[]): Reventless.Plugin.writableDef => {
  name,
  commands: [],
  producedEventTypes: produces,
  consumedEventTypes: consumes,
  linkedViews,
  consistencyRead: None,
}

let queryable = (~name, ~consumes=[]): Reventless.Plugin.queryableDef => {
  name,
  queryField: "",
  schema: "",
  consumedEventTypes: consumes,
  linkedWriteSide: [],
  labelField: "id",
  searchableFields: [],
  statusField: None,
  visibility: None,
}

let automation = (~name, ~consumes=[]): Reventless.Plugin.automationSliceDef => {
  name,
  consumedEventTypes: consumes,
  producedCommandTypes: [],
  targetName: "",
}

let structure = (
  ~aggregates=[],
  ~readModels=[],
  ~stateViewSlices=[],
  ~stateChangeSlices=[],
  ~automationSlices=[],
  ~outboundTranslationSlices=[],
  ~extensions=[],
): Reventless.Plugin.pluginStructure => {
  readModels,
  stateViewSlices,
  stateChangeSlices,
  aggregates,
  automationSlices,
  outboundTranslationSlices,
  inboundTranslationSlices: [],
  extensions,
  extensionPoints: None,
}

describe("DomainDeadCode.analyze — orphan events", () => {
  testPromise("flags a produced event no component consumes", async () => {
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed", "Shop.Archived"])],
      ~readModels=[queryable(~name="Orders", ~consumes=["Shop.Placed"])],
    )
    let findings = DomainDeadCode.analyze(~structures=[("Shop", shop)], ~edges=[])
    expect(findings->Array.map(f => f.detail))->toEqual(["Shop.Archived"])
    let f = findings->Array.getUnsafe(0)
    expect((f.kind, f.pluginName, f.componentName))->toEqual(("OrphanEvent", "Shop", "Order"))
  })

  testPromise("a consumer in ANY plugin clears the orphan (cross-plugin)", async () => {
    let shop = structure(~aggregates=[writable(~name="Order", ~produces=["Shop.Placed"])])
    let analytics = structure(~automationSlices=[automation(~name="OnPlaced", ~consumes=["Shop.Placed"])])
    let findings = DomainDeadCode.analyze(
      ~structures=[("Shop", shop), ("Analytics", analytics)],
      ~edges=[],
    )
    expect(findings->Array.length)->toBe(0)
  })

  testPromise("consumption via a state-view slice and a state-change DCB read both count", async () => {
    let s = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed", "Shop.Shipped"])],
      ~stateViewSlices=[queryable(~name="OrderView", ~consumes=["Shop.Placed"])],
      ~stateChangeSlices=[writable(~name="Ship", ~consumes=["Shop.Shipped"])],
    )
    let findings = DomainDeadCode.analyze(~structures=[("Shop", s)], ~edges=[])
    expect(findings->Array.length)->toBe(0)
  })

  testPromise("edge viaEvents marks an event consumed (reachability over the graph)", async () => {
    let shop = structure(~aggregates=[writable(~name="Order", ~produces=["Shop.Placed"])])
    let edge: Reventless.Plugin.graphEdge = {
      source: {pluginName: "Shop", componentName: "Order", kind: "Aggregate"},
      target: {pluginName: "Other", componentName: "X", kind: "StateViewSlice"},
      mechanism: "EventTypeMatch",
      viaEvents: ["Shop.Placed"],
      implicit: false,
    }
    let findings = DomainDeadCode.analyze(~structures=[("Shop", shop)], ~edges=[edge])
    expect(findings->Array.length)->toBe(0)
  })

  testPromise("a linked classic read model clears all the aggregate's events (rule 2)", async () => {
    // Classic aggregate → read-model link lives on the producer (`linkedViews`); the
    // read model's consumedEventTypes is empty. The aggregate must not be flagged.
    let shop = structure(
      ~aggregates=[
        writable(~name="Order", ~produces=["Shop.Placed", "Shop.Archived"], ~linkedViews=["Orders"]),
      ],
      ~readModels=[queryable(~name="Orders")],
    )
    let findings = DomainDeadCode.analyze(~structures=[("Shop", shop)], ~edges=[])
    expect(findings->Array.length)->toBe(0)
  })

  testPromise("an aggregate with no view and no consumer is fully orphaned", async () => {
    let shop = structure(~aggregates=[writable(~name="Audit", ~produces=["Shop.Logged"])])
    let findings = DomainDeadCode.analyze(~structures=[("Shop", shop)], ~edges=[])
    expect(findings->Array.map(f => f.detail))->toEqual(["Shop.Logged"])
  })

  testPromise("state-change slices are scanned as producers too", async () => {
    let s = structure(
      ~stateChangeSlices=[writable(~name="Reserve", ~produces=["Shop.Reserved"])],
    )
    let findings = DomainDeadCode.analyze(~structures=[("Shop", s)], ~edges=[])
    expect(findings->Array.map(f => (f.componentName, f.detail)))->toEqual([("Reserve", "Shop.Reserved")])
  })
})
