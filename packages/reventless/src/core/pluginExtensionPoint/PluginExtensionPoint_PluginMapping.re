module Impl = {
  open ExtensionPointMapping;

  module Aggregate = PluginSpec;

  let mapIncomingCommand = (id, cmd, _meta) =>
    switch (cmd) {
    | PluginExtensionPointSpec.Heartbeat => [|
        PublishCommand(id->Id.String.toString, Aggregate.Heartbeat),
        Call(
          _cmd => Js.Promise.resolve(),
          PluginExtensionPointSpec.ConfigAlarm,
        ),
      |]
    | _ => [||]
    };

  let mapOutgoingEvent = (id, event, _meta) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(
          id->Aggregate.Id.toString,
          PluginExtensionPointSpec.UnknownPluginDetected,
        ),
      |]
    | _ => [||]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
