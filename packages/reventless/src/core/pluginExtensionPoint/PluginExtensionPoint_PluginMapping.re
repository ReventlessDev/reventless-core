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
          meta:
            Message.generateMeta(
              ~service="Core.Plugin",
              ~user="Scheduler",
              (),
            ),
          command: PluginExtensionPointSpec.DisconnectPlugin,
        }
        |> Message.command'_encode(
             Decco.stringToJson,
             PluginExtensionPointSpec.command_encode,
           )
        |> Js.Json.stringify,
    })
  | DeleteDisconnectSchedule(id) => deleteSchedule(. id)
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

  let mapIncomingCommand = (id, cmd, _meta: Message.meta) =>
    switch (cmd) {
    | PluginExtensionPointSpec.Heartbeat(timeout) => [|
        PublishCommand(id, Aggregate.Heartbeat),
        // Re-create timeout (+1 minute to avoid toggling)
        Call(callHandler, CreateDisconnectSchedule(id, timeout + 1)),
      |]
    | ConnectPlugin(pluginDefinition) => [|
        PublishCommand(id, ConnectPlugin(pluginDefinition)),
      |]
    | DisconnectPlugin => [|
        PublishCommand(id, DisconnectPlugin),
        Call(callHandler, DeleteDisconnectSchedule(id)),
      |]
    | ForwardCommand(forwardCommand) => [|
        Call(callHandler, ForwardCommand(forwardCommand)),
      |]
    };

  let mapOutgoingEvent = (id, event, _meta, _pluginDef) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(id, PluginExtensionPointSpec.UnknownPluginDetected),
      |]
    | PluginConnected(pluginDefinition) => [|
        PublishEvent(id, PluginConnected(pluginDefinition)),
      |]
    | PluginReconnected(pluginDefinition) => [|
        PublishEvent(id, PluginReconnected(pluginDefinition)),
      |]
    | PluginDisconnected(pluginDefinition) => [|
        PublishEvent(id, PluginDisconnected(pluginDefinition)),
      |]
    | PluginDeactivated(pluginDefinition) => [|
        PublishEvent(id, PluginDeactivated(pluginDefinition)),
      |]
    | PluginActivated(pluginDefinition) => [|
        PublishEvent(id, PluginActivated(pluginDefinition)),
      |]
    };
};

module Mapping = ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl);
