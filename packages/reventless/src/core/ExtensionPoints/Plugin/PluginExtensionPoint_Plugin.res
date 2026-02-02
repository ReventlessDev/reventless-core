open ReventlessSpec.ExtensionPointMapping
open ReventlessSpec.Plugin

let forwardCommand = async (
  _id,
  command,
  extensionPointName,
  queryEngine: ReventlessSpec.QueryEngine.operations,
) =>
  switch await queryEngine.scan(
    ~readModelName=PluginSpec.name,
    ~filterConfigs=[
      ("extensionPointNames", Contains, String(extensionPointName)),
      ("status", Contains, String("Connected")),
    ],
    ~limit=1000,
  ) {
  | jsons =>
    switch jsons {
    | [] =>
      Console.log2("ForwardCommand: Couldn't find Plugin with ExtensionPoint", extensionPointName)
    | plugins =>
      let plugin = plugins->Array.getUnsafe(0)
      switch plugin->Message.decode(PluginReadModelSpec.stateSchema) {
      | plugin =>
        let extensionPoint =
          plugin.extensionPoints->Array.find(extensionPoint =>
            extensionPoint.name == extensionPointName
          )
        switch extensionPoint {
        | Some(extensionPoint) =>
          switch await AwsSdk.SQS.sendMessage(
            ~queueId=extensionPoint.commandTopic,
            ~messageBody=command,
          ) {
          | _ =>
            Console.log3(
              "ForwardCommand: published command to",
              plugin.name,
              extensionPoint.commandTopic,
            )
          | exception err =>
            Console.log2("PluginExtensionPoint_PluginMapping: Error on publish command:", err)
          }

        | None =>
          Console.log3("ForwardCommand: Couldn't find ExtensionPoint", extensionPointName, plugin)
        }
      | exception err => Console.log3("ForwardCommand: Couldn't decode Plugin", plugin, err)
      }
    }
  }

let callHandler = async (
  createSchedule: ReventlessSpec.Schedule.create,
  deleteSchedule: ReventlessSpec.Schedule.delete,
  queryEngine: ReventlessSpec.QueryEngine.operations,
  callCommand,
) =>
  switch callCommand {
  | ReventlessSpec.PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout) =>
    await createSchedule({
      name: PulumiAws.Lambda.environment->Option.getOr("unknownEnv") ++ ("-" ++ id),
      rate: timeout->Schedule.minutesFromNow,
      payload: {
        Message.id,
        meta: Message.generateMeta(~service="Core.Plugin", ~user="Scheduler"),
        command: ReventlessSpec.PluginExtensionPointSpec.DisconnectPlugin,
      }
      ->Message.encodeCommand'(S.string, ReventlessSpec.PluginExtensionPointSpec.commandSchema)
      ->JSON.stringify,
    })
  | DeleteDisconnectSchedule(id) => await deleteSchedule(id)
  | ForwardCommand({id, command, extensionPointName}) =>
    await forwardCommand(id, command, extensionPointName, queryEngine)
  | _ => ()
  }

module Impl = {
  module Aggregate = PluginSpec

  let mapIncomingCommand = (id, cmd, _meta: Message.meta) =>
    switch cmd {
    | ReventlessSpec.PluginExtensionPointSpec.Heartbeat(interval) => [
        PublishCommand(id, Aggregate.Heartbeat),
        // Re-create timeout (+2 minute to avoid toggling)
        // 1 minute because Schedules can only be created by minute
        // 1 additional minute to allow additional latency
        Call(callHandler, CreateDisconnectSchedule(id, interval + 2)),
      ]
    | ConnectPlugin(pluginDefinition) => [PublishCommand(id, Connect(pluginDefinition))]
    | DisconnectPlugin => [
        PublishCommand(id, Disconnect),
        Call(callHandler, DeleteDisconnectSchedule(id)),
      ]
    | ForwardCommand(forwardCommand) => [Call(callHandler, ForwardCommand(forwardCommand))]
    }

  let mapOutgoingEvent = Some(
    (id, event, _meta, _queryEngine) =>
      switch event {
      | Aggregate.UnknownPluginDetected => [
          PublishEvent(id, ReventlessSpec.PluginExtensionPointSpec.UnknownPluginDetected),
        ]
      | Connected(pluginDefinition) => [PublishEvent(id, PluginConnected(pluginDefinition))]
      | Reconnected(pluginDefinition) => [PublishEvent(id, PluginReconnected(pluginDefinition))]
      | Disconnected(pluginDefinition) => [PublishEvent(id, PluginDisconnected(pluginDefinition))]
      | Deactivated(pluginDefinition) => [PublishEvent(id, PluginDeactivated(pluginDefinition))]
      | Activated(pluginDefinition) => [PublishEvent(id, PluginActivated(pluginDefinition))]
      },
  )
}

module Mapping = ExtensionPointMapping.Make(ReventlessSpec.PluginExtensionPointSpec, Impl)
