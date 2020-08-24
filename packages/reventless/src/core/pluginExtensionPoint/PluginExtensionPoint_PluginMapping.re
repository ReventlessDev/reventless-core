module Impl = {
  open PluginExtensionPointSpec;
  open ExtensionPointMapping;

  module Aggregate = PluginSpec;

  let mapIncomingCommand =
      (id, cmd, _meta)
      : commandActions((Aggregate.Id.t, Aggregate.command), callCommand) =>
    switch (cmd) {
    | Heartbeat => [|
        PublishCommand(
          Aggregate.name,
          (
            id->Id.String.toString->Aggregate.Id.makeFromString,
            Aggregate.Heartbeat,
          ),
        ),
      |]
    | _ => [||]
    };

  let mapOutgoingEvent = (id, event, _meta) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent((
          id->Aggregate.Id.toString->Id.String.makeFromString,
          UnknownPluginDetected,
        )),
      |]
    | _ => [||]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
