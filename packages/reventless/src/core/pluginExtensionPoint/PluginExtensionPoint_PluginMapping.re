let callHandler =
    (
      createSchedule: Schedule.create,
      deleteSchedule: Schedule.delete,
      queryEngine: QueryDb.queryEngine,
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
    queryEngine.scan(
      ~serviceName=PluginSpec.name,
      ~filterConfigs=[
        ("extensionPointNames", Contains, String(extensionPointName)),
        ("status", Contains, String("Connected")),
      ],
      ~limit=1,
    )
    ->Js.Promise.then_(
        fun
        | [||] =>
          Js.log2(
            "ForwardCommand: Couldn't find Plugin with ExtensionPoint",
            extensionPointName,
          )
          ->Js.Promise.resolve
        | plugins => {
            let plugin = plugins->Belt.Array.getExn(0);
            plugin
            ->PluginView.state_decode
            ->(
                fun
                | Belt.Result.Ok((plugin: PluginView.state)) => {
                    plugin.extensionPoints
                    ->Belt.Array.getBy(extensionPoint =>
                        extensionPoint.name == extensionPointName
                      )
                    ->(
                        fun
                        | Some(extensionPoint) =>
                          command
                          ->AwsSdk.SQS.sendMessage(
                              ~queueId=extensionPoint.PluginSpec.commandTopic,
                              ~messageBody=_,
                              (),
                            )
                          ->Js.Promise.then_(
                              _ =>
                                Js.log3(
                                  "ForwardCommand: published command to",
                                  plugin.name,
                                  extensionPoint.PluginSpec.commandTopic,
                                )
                                ->Js.Promise.resolve,
                              _,
                            )
                          ->Js.Promise.catch(
                              err =>
                                Js.log2(
                                  "PluginExtensionPoint_PluginMapping: Error on publish command:",
                                  err,
                                )
                                ->Js.Promise.resolve,
                              _,
                            )
                        | None =>
                          Js.log3(
                            "ForwardCommand: Couldn't find ExtensionPoint",
                            extensionPointName,
                            plugin,
                          )
                          ->Js.Promise.resolve
                      );
                  }
                | Error(err) =>
                  Js.log3(
                    "ForwardCommand: Couldn't decode Plugin",
                    plugin,
                    err,
                  )
                  ->Js.Promise.resolve
              );
          },
        _,
      )
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
