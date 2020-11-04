open PluginSpec;

let pluginDefinition = {
  id: "id@1",
  name: "name",
  version: "1",
  extensionPoints: [||],
  extensions: [|
    {name: "Core.Plugin.Test", extensionPointName: "Core.Plugin"},
  |],
  eventCollector: "eventCollector",
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

let extensionPointNames2 = [|"Test"|];
let pluginDefinition2 = {
  id: "id2@1",
  name: "name2",
  version: "1",
  extensionPoints:
    extensionPointNames2->Belt.Array.mapWithIndex((idx, name) =>
      {
        name,
        commandTopic: {j|commandTopic$idx|j},
        eventTopic: {j|eventTopic$idx|j},
      }
    ),
  extensions: [||],
  eventCollector: "eventCollector",
};
