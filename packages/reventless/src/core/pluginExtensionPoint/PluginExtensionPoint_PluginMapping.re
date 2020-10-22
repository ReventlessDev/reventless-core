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
      rate: timeout->Schedule.minutesFromNow,
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
  | ForwardCommand({extensionPointName, command}) =>
    // TODO: query all Plugins from ReadModel
    // TODO: find first Plugin which holds an extension point named like the one in the command
    // TODO: get queue id for extension point
    // TODO: send command
    Js.log3(
      "TODO: IMPLEMENT CallCommand handling for ForwardCommand:",
      extensionPointName,
      command,
    )
    ->Js.Promise.resolve
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
    | PluginExtensionPointSpec.ConnectPlugin(pluginDefinition) => [|
        PublishCommand(id, Aggregate.ConnectPlugin(pluginDefinition)),
      |]
    | PluginExtensionPointSpec.DisconnectPlugin => [|
        PublishCommand(id, Aggregate.DisconnectPlugin),
        Call(
          callHandler,
          PluginExtensionPointSpec.DeleteDisconnectSchedule(id),
        ),
      |]
    | ForwardCommand(publishCommandDefinition) => [|
        Call(callHandler, ForwardCommand(publishCommandDefinition)),
      |]
    };

  let mapOutgoingEvent = (id, event, _meta) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(id, PluginExtensionPointSpec.UnknownPluginDetected),
      |]
    | Aggregate.PluginConnected(pluginDefinition) => [|
        PublishEvent(
          id,
          PluginExtensionPointSpec.PluginConnected(pluginDefinition),
        ),
      |]
    | Aggregate.PluginReconnected(pluginDefinition) => [|
        PublishEvent(
          id,
          PluginExtensionPointSpec.PluginReconnected(pluginDefinition),
        ),
      |]
    | Aggregate.PluginDisconnected(pluginDefinition) => [|
        PublishEvent(
          id,
          PluginExtensionPointSpec.PluginDisconnected(pluginDefinition),
        ),
      |]
    | Aggregate.PluginDeactivated(pluginDefinition) => [|
        PublishEvent(
          id,
          PluginExtensionPointSpec.PluginDeactivated(pluginDefinition),
        ),
      |]
    | Aggregate.PluginActivated(pluginDefinition) => [|
        PublishEvent(
          id,
          PluginExtensionPointSpec.PluginActivated(pluginDefinition),
        ),
      |]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
