open PluginSpec;

let pluginDefinition = {
  name: "test-plugin-1",
  version: "1",
  extensionPoints: [||],
  extensions: [|
    {name: "Core.Plugin", extensionPointName: "Core.Plugin.Connect"},
  |],
  eventCollector: "URN",
};

let state: PluginView.state = {
  name: pluginDefinition.name,
  version: pluginDefinition.version,
  extensionPoints: pluginDefinition.extensionPoints,
  extensionPointNames:
    pluginDefinition.extensionPoints->PluginView.extractNames,
  extensions: pluginDefinition.extensions,
  status: Connected,
  statusChange: TestFixtures.statusChange,
};

let pluginDefinition2 = {
  name: "test-plugin-2",
  version: "1",
  extensionPoints: [|
    {
      name: "six-sanctions-geos-export",
      commandTopic: "ct1",
      eventTopic: "et1",
    },
  |],
  extensions: [||],
  eventCollector: "URN",
};
