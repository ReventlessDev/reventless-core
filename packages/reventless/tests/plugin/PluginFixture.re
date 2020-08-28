open PluginSpec;

let plugin1 = {
  name: "test-plugin-1",
  version: "1",
  extensionPoints: [||],
  extensions: [|{name: "six-sanctions-geos-export", eventCollector: "ec1"}|],
};

let state1: PluginView.state = {
  name: plugin1.name,
  version: plugin1.version,
  extensionPoints: plugin1.extensionPoints,
  extensions: plugin1.extensions,
  status: Connected,
  since: TestFixtures.context.meta.time,
};

let plugin2 = {
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
};
