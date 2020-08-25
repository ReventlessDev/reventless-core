let handler =
  fun
  | PluginExtensionPointSpec.ConfigAlarm(id, timeout) =>
    Js.log({j|ConfigAlarm($id, $timeout)|j})->Js.Promise.resolve;

module Impl = {
  open ExtensionPointMapping;

  module Aggregate = PluginSpec;

  let mapIncomingCommand = (id, cmd, _meta) =>
    switch (cmd) {
    | PluginExtensionPointSpec.Heartbeat(timeout) => [|
        PublishCommand(id, Aggregate.Heartbeat),
        Call(handler, PluginExtensionPointSpec.ConfigAlarm(id, timeout)),
      |]
    | PluginExtensionPointSpec.ConnectPlugin(plugin) => [|
        PublishCommand(id, Aggregate.ConnectPlugin(plugin)),
      |]
    | PluginExtensionPointSpec.DisconnectPlugin => [|
        PublishCommand(id, Aggregate.DisconnectPlugin),
      |]
    };

  let mapOutgoingEvent = (id, event, _meta) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(id, PluginExtensionPointSpec.UnknownPluginDetected),
      |]
    | Aggregate.PluginConnected(plugin) => [|
        PublishEvent(id, PluginExtensionPointSpec.PluginConnected(plugin)),
      |]
    | Aggregate.PluginDisconnected => [|
        PublishEvent(id, PluginExtensionPointSpec.PluginDisconnected),
      |]
    | Aggregate.PluginDeactivated => [|
        PublishEvent(id, PluginExtensionPointSpec.PluginDeactivated),
      |]
    | Aggregate.PluginActivated => [|
        PublishEvent(id, PluginExtensionPointSpec.PluginActivated),
      |]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
