module Impl = {
  open PluginExtensionPointSpec;
  open ExtensionPointMapping;

  module Aggregate = PluginSpec;

  let mapIncomingCommand:
    mapIncomingCommand(
      command,
      Aggregate.Id.t,
      Aggregate.command,
      callCommand,
    ) =
    (id, cmd, _meta) =>
      switch (cmd) {
      | Heartbeat => [|
          PublishCommand(
            id->Id.String.toString->Aggregate.Id.makeFromString,
            Aggregate.Heartbeat,
          ),
        |]
      | _ => [||]
      };

  let mapOutgoingEvent = (id, event, _meta) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(
          id->Aggregate.Id.toString->Id.String.makeFromString,
          UnknownPluginDetected,
        ),
      |]
    | _ => [||]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
