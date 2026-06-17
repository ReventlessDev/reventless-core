open ReventlessCore
open PluginSpec
open Plugin_Fixtures
module PluginHistoryProjectionTest = ReventlessGwt.MultiSourceProjection_GWT.Make(
  PluginHistoryProjection.HistoryMapping,
)
open PluginHistoryProjectionTest

// Rich audit view (timeline). One row per transition, keyed by name (partition,
// = the aggregate id "id") + `version#transitionAt#transition` (sort). Built via
// the projection's own `entry` so assertions match output exactly.

let sc = ReventlessGwt.TestFixtures.statusChange
let id = ReventlessGwt.TestFixtures.id

// Expected timeline row at the default harness time/user.
let row = (~version, ~transition, ~supersededVersion=?) =>
  PluginHistoryProjection.entry(
    ~name=id,
    ~version,
    ~transition,
    ~transitionAt=sc.at,
    ~by=sc.by,
    ~supersededVersion?,
  )

// Expected row at an explicit time (for multi-transition timelines, which need
// distinct sort keys per transition).
let rowAt = (~version, ~transition, ~at, ~supersededVersion=?) =>
  PluginHistoryProjection.entry(
    ~name=id,
    ~version,
    ~transition,
    ~transitionAt=at,
    ~by=sc.by,
    ~supersededVersion?,
  )

let supersededV1ByV2 = VersionSuperseded({
  supersededVersion: "1",
  supersededDefinition: pluginDefinition,
  newVersion: "2",
  newDefinition: pluginDefinitionV2,
})

describe("PluginHistoryProjection:", () => {
  test("VersionDetected records a Detected row", () =>
    givenEvents([])
    ->whenEvent(VersionDetected("1"))
    ->thenStates([row(~version="1", ~transition=Detected)])
  )

  test("VersionConnected records a Connected row", () =>
    givenEvents([])
    ->whenEvent(VersionConnected(pluginDefinition))
    ->thenStates([row(~version="1", ~transition=Connected)])
  )

  test("VersionSuperseded records the supersession edge (new version, superseded version)", () =>
    givenEvents([])
    ->whenEvent(supersededV1ByV2)
    ->thenStates([row(~version="2", ~transition=Superseded, ~supersededVersion="1")])
  )

  test("VersionDisconnected records a Disconnected row", () =>
    givenEvents([])
    ->whenEvent(VersionDisconnected(pluginDefinition))
    ->thenStates([row(~version="1", ~transition=Disconnected)])
  )

  test("VersionRetired records a Retired row", () =>
    givenEvents([])
    ->whenEvent(VersionRetired(pluginDefinition))
    ->thenStates([row(~version="1", ~transition=Retired)])
  )

  test("UIFragment events are not part of the timeline", () =>
    givenEvents([VersionConnected(pluginDefinition)])
    ->whenEvents([
      UIFragmentRegistered({pluginId: pluginDefinition.id, manifest: uiManifest}),
      UIFragmentDeregistered({pluginId: pluginDefinition.id}),
    ])
    ->thenStates([row(~version="1", ~transition=Connected)])
  )

  test("a full arc appends one row per transition, ordered by version#time", () =>
    givenEventsWithTime([
      ("t1", VersionDetected("1")),
      ("t2", VersionConnected(pluginDefinition)),
      ("t3", VersionDisconnected(pluginDefinition)),
    ])
    ->whenEventWithTime("t4", VersionConnected(pluginDefinition))
    ->thenStates([
      rowAt(~version="1", ~transition=Detected, ~at="t1"),
      rowAt(~version="1", ~transition=Connected, ~at="t2"),
      rowAt(~version="1", ~transition=Disconnected, ~at="t3"),
      rowAt(~version="1", ~transition=Connected, ~at="t4"),
    ])
  )

  test("supersession across versions keeps both versions' rows", () =>
    givenEventsWithTime([
      ("t1", VersionConnected(pluginDefinition)),
      ("t2", VersionConnected(pluginDefinitionV2)),
    ])
    ->whenEventWithTime(
      "t2",
      VersionSuperseded({
        supersededVersion: "1",
        supersededDefinition: pluginDefinition,
        newVersion: "2",
        newDefinition: pluginDefinitionV2,
      }),
    )
    ->thenStates([
      rowAt(~version="1", ~transition=Connected, ~at="t1"),
      rowAt(~version="2", ~transition=Connected, ~at="t2"),
      rowAt(~version="2", ~transition=Superseded, ~at="t2", ~supersededVersion="1"),
    ])
  )
})
