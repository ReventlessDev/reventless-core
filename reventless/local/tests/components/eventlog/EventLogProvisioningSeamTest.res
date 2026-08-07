// End-to-end check that the EventLogProvisioning seam fires from the real
// builders, not just from its own registry: a backend registered before the
// build sees both log styles as they are provisioned, through the local
// in-memory storage adapters.
//
// Registration and construction happen at module load — the seam fires during
// `Component.make`'s construct, so a backend registered inside a `test` body
// would arrive too late. The assertions then read what was recorded.

open JestGlobals

type record = {
  logStyle: ReventlessCore.EventLogProvisioning.logStyle,
  name: string,
  owner: option<ReventlessCore.ResourceAttribution.owner>,
  plugin: option<string>,
  resourceCount: int,
}

let provisioned: array<record> = []

module Recorder: ReventlessCore.EventLogProvisioning.Backend = {
  let onProvisioned = (~logStyle, ~name, ~owner, ~plugin, ~platform as _, ~resources, ~opts as _) =>
    provisioned->Array.push({
      logStyle,
      name,
      owner,
      plugin,
      resourceCount: resources->Array.length,
    })
}

ReventlessCore.EventLogProvisioning.use(module(Recorder: ReventlessCore.EventLogProvisioning.Backend))

module Bus = LocalBus.Make()

let _ = TestRunner.setup()

// ── Classic log ──────────────────────────────────────────────
module SeamItemSpec = {
  module Id = Reventless.Id.StringPure
  let name = "SeamItemEventLog"

  @schema
  type event = | SeamItemCreated({name: string})
}

module ClassicMaker = ReventlessCore.EventLog_Builder.Make(
  SeamItemSpec,
  EventLogStorage_InMemory,
  LocalEventTopicPublisher.Make(Bus),
)

// The plugin builder publishes this context around a plugin's construct; entering
// it here is what a real plugin build does, so the seam should carry the names.
let previousContext = ReventlessCore.ResourceAttribution.enter(~platform="seam-platform", ~plugin="SeamPlugin")

let classicLog = ClassicMaker.make(
  ~name="SeamItem",
  ~owner={kind: ReventlessCore.ComponentType.Aggregate, name: "SeamItem"},
)

// ── DCB log ──────────────────────────────────────────────────
module DcbMaker = DcbEventLog_Builder.Make(Bus)

let dcbLog = DcbMaker.make(
  ~name="SeamCatalog",
  ~partitionTag=Reventless.DcbTag.Simple({key: "id"}),
)

ReventlessCore.ResourceAttribution.restore(previousContext)

describe("EventLogProvisioning seam, driven by the real builders", () => {
  testSync("fires once per log, for both styles", () => {
    expect(provisioned->Array.map(r => (r.logStyle, r.name)))->toEqual([
      (ReventlessCore.EventLogProvisioning.Classic, "SeamItemEventLog"),
      (ReventlessCore.EventLogProvisioning.Dcb, "SeamCatalogDcbEventLog"),
    ])
  })

  testSync("carries the owning element: the aggregate for classic, the plugin for DCB", () => {
    expect(provisioned->Array.map(r => r.owner))->toEqual([
      Some(({kind: ReventlessCore.ComponentType.Aggregate, name: "SeamItem"}: ReventlessCore.ResourceAttribution.owner)),
      Some(({kind: ReventlessCore.ComponentType.Plugin, name: "SeamCatalog"}: ReventlessCore.ResourceAttribution.owner)),
    ])
  })

  testSync("carries the ambient plugin attribution the builder published", () => {
    expect(provisioned->Array.map(r => r.plugin))->toEqual([
      Some("SeamPlugin"),
      Some("SeamPlugin"),
    ])
  })

  testSync("carries the adapter's resources — empty for in-memory storage", () => {
    // In-memory logs have nothing attachable; the seam still fires, and a backend
    // that only implements a provider arm ignores them.
    expect(provisioned->Array.map(r => r.resourceCount))->toEqual([0, 0])
  })

  test("the components still build normally with a backend registered", async () => {
    let classicOps = await classicLog->ReventlessCore.Component.operations->TestRunner.resolve
    let dcbOps = await dcbLog->DcbMaker.operations->TestRunner.resolve
    // Resolving both operation records proves construction completed with a
    // backend registered — the seam fires mid-construct, so a throwing backend
    // would take the build down here.
    expect(classicOps)->toBeTruthy
    expect(dcbOps)->toBeTruthy
  })
})
