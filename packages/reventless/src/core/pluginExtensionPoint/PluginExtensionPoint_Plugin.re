open ReventlessSpec.ExtensionPointMapping;

let forwardCommand =
    (
      id,
      command,
      extensionPointName,
      queryEngine: ReventlessSpec.QueryEngine.t,
    ) =>
  queryEngine.scan(
    ~serviceName=PluginSpec.name,
    ~filterConfigs=[
      ("extensionPointNames", Contains, String(extensionPointName)),
      ("status", Contains, String("Connected")),
    ],
    ~limit=1000,
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
                            ~queueId=extensionPoint.commandTopic,
                            ~messageGroupId=id,
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
                Js.log3("ForwardCommand: Couldn't decode Plugin", plugin, err)
                ->Js.Promise.resolve
            );
        },
      _,
    );

let callHandler =
    (
      createSchedule: ReventlessSpec.Schedule.create,
      deleteSchedule: ReventlessSpec.Schedule.delete,
      queryEngine: ReventlessSpec.QueryEngine.t,
      callCommand,
    ) =>
  switch (callCommand) {
  | ReventlessSpec.PluginExtensionPointSpec.CreateDisconnectSchedule(
      id,
      timeout,
    ) =>
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
          command: ReventlessSpec.PluginExtensionPointSpec.DisconnectPlugin,
        }
        |> Message.command'_encode(
             Decco.stringToJson,
             ReventlessSpec.PluginExtensionPointSpec.command_encode,
           )
        |> Js.Json.stringify,
    })
  | DeleteDisconnectSchedule(id) => deleteSchedule(. id)
  | ForwardCommand({id, command, extensionPointName}) =>
    forwardCommand(id, command, extensionPointName, queryEngine)
  | _ => Js.Promise.resolve()
  };

module Impl = {
  module Aggregate = PluginSpec;

  let mapIncomingCommand = (id, cmd, _meta: Message.meta) =>
    switch (cmd) {
    | ReventlessSpec.PluginExtensionPointSpec.Heartbeat(interval) => [|
        PublishCommand(id, Aggregate.Heartbeat),
        // Re-create timeout (+2 minute to avoid toggling)
        // 1 minute because Schedules can only be created by minute
        // 1 additional minute to allow additional latency
        Call(callHandler, CreateDisconnectSchedule(id, interval + 2)),
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

  let mapOutgoingEvent = (id, event, _meta, _queryEngine) =>
    switch (event) {
    | Aggregate.UnknownPluginDetected => [|
        PublishEvent(
          id,
          ReventlessSpec.PluginExtensionPointSpec.UnknownPluginDetected,
        ),
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

module Mapping =
  ExtensionPointMapping.Make(ReventlessSpec.PluginExtensionPointSpec, Impl);
