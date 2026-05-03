open ReventlessCore

let pluginDefinition = {
  Reventless.Plugin.id: "id@1",
  name: "name",
  version: "1",
  extensionPoints: [],
  extensions: [{name: "Core.Plugin.Test", extensionPointName: "Core.Plugin"}],
  eventCollector: "eventCollector",
  extensionProtocols: [],
  apiSchemaFragment: None,
  apiTarget: None,
  uiFragments: None,
  structure: None,
}

let state: PluginReadModelSpec.state = {
  name: pluginDefinition.name,
  version: pluginDefinition.version,
  eventCollector: pluginDefinition.eventCollector,
  extensionPoints: pluginDefinition.extensionPoints,
  extensionPointNames: pluginDefinition.extensionPoints->PluginProjection.Util.extractExtensionPointNames,
  extensionNames: pluginDefinition.extensions->PluginProjection.Util.extractExtensionNames,
  extensions: pluginDefinition.extensions,
  status: Connected,
  statusChange: ReventlessGwt.TestFixtures.statusChange,
  apiSchemaFragment: None,
  uiFragments: None,
  structure: None,
}

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
  Reventless.Plugin.id: "id2@1",
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
}
