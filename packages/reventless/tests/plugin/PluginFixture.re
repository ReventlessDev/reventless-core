open PluginSpec;

let plugin1 = {
  name: "test-plugin-1",
  version: "1",
  extensionPoints: [||],
  extensions: [|
    {id: "six-sanctions-geos-export", commandTopic: "ct1", eventTopic: "et1"},
  |],
};

let plugin2 = {
  name: "test-plugin-2",
  version: "1",
  extensionPoints: [|
    {id: "six-sanctions-geos-export", commandTopic: "ct1", eventTopic: "et1"},
  |],
  extensions: [||],
};
