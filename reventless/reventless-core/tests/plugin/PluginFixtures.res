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
  statusChange: TestFixtures.statusChange,
  apiSchemaFragment: None,
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
}
