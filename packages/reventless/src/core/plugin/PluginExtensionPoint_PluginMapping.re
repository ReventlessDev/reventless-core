let callHandler =
    (
      createSchedule: Schedule.create,
      deleteSchedule: Schedule.delete,
      callCommand,
    ) =>
  switch (callCommand) {
  | PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout) =>
    createSchedule(. {
      name: id, // TODO: prefix with Pulumi.Pulumi.getStackName()
      rate: timeout->Minutes,
      payload:
        {
          Message.id,
          meta: Message.generateMeta("Core.Plugin", "", "Scheduler"),
          command: PluginExtensionPointSpec.DisconnectPlugin,
        }
        |> Message.command'_encode(
             Decco.stringToJson,
             PluginExtensionPointSpec.command_encode,
           )
        |> Js.Json.stringify,
    })
  | PluginExtensionPointSpec.DeleteDisconnectSchedule(id) =>
    deleteSchedule(. id)
  | _ => Js.Promise.resolve()
  };

module Impl = {
  open ExtensionPointMapping;

  module Aggregate = PluginSpec;

  let mapIncomingCommand = (id, cmd, _meta) =>
    switch (cmd) {
    | PluginExtensionPointSpec.Heartbeat(timeout) => [|
        PublishCommand(id, Aggregate.Heartbeat),
        // Re-create timeout (+1 minute to avoid toggling)
        Call(
          callHandler,
          PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout + 1),
        ),
      |]
    | PluginExtensionPointSpec.ConnectPlugin(plugin) => [|
        PublishCommand(id, Aggregate.ConnectPlugin(plugin)),
      |]
    | PluginExtensionPointSpec.DisconnectPlugin => [|
        PublishCommand(id, Aggregate.DisconnectPlugin),
        Call(
          callHandler,
          PluginExtensionPointSpec.DeleteDisconnectSchedule(id),
        ),
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
    | Aggregate.PluginReconnected => [|
        PublishEvent(id, PluginExtensionPointSpec.PluginReconnected),
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
