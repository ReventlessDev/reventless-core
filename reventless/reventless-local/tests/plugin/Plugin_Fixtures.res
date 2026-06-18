open ReventlessCore

let sc = ReventlessGwt.TestFixtures.statusChange

let pluginDefinition: Reventless.Plugin.pluginDefinition = {
  id: "name@1",
  name: "name",
  version: "1",
  extensionPoints: [],
  extensions: [{name: "Core.Plugin.Test", extensionPointName: "Core.Plugin", dcbSources: []}],
  eventCollector: "eventCollector",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  uiFragments: None,
  structure: None,
  dcbEventLog: None,
}

// A higher version of the SAME plugin name — for supersession / rollback tests.
let pluginDefinitionV2 = {...pluginDefinition, id: "name@2", version: "2"}

// Expected current-view row for a def + status + the OTHER currently-connected
// versions (own version excluded). Reuses the projection's own builder so
// assertions match the projection output exactly.
let display = (def, status, otherConnectedVersions): PluginsReadModelSpec.state =>
  PluginsProjection.displayState(def, status, sc, otherConnectedVersions)

// Canonical v1 Connected current-view row — no other versions live.
let state: PluginsReadModelSpec.state = display(pluginDefinition, Connected, [])

let uiManifest: Reventless.Plugin.uiFragmentManifest = {
  remoteEntryUrl: "https://cdn.example.com/plugin@1.0/remoteEntry.js",
  panels: [],
  pages: [],
}

let pluginDefinitionWithUI = {
  ...pluginDefinition,
  uiFragments: Some(uiManifest),
}

let extensionPointNames2 = ["Test.Test"]
let pluginDefinition2 = {
  Reventless.Plugin.id: "name2@1",
  name: "name2",
  version: "1",
  extensionPoints: extensionPointNames2->Array.mapWithIndex((name, idx) => {
    Reventless.Plugin.name,
    commandTopic: `commandTopic${idx->Int.toString}`,
    eventTopic: `eventTopic${idx->Int.toString}`,
  }),
  extensions: [],
  eventCollector: "eventCollector",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  uiFragments: None,
  structure: None,
  dcbEventLog: None,
}
