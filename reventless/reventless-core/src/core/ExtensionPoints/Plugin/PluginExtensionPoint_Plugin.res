open Reventless.ExtensionPointMapping
open Reventless.Plugin

module PluginExtensionPointSpec = Reventless.PluginExtensionPointSpec

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let environment: string
}

module Make = (Spec: Spec) => {
  let forwardCommand = async (
    _id,
    command,
    extensionPointName,
    queryEngine: Reventless.QueryEngine.operations,
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
            switch await Spec.runtimeOps.messagePublish.sendMessageToChannel(
              ~channelId=extensionPoint.commandTopic,
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
    createSchedule: Reventless.Schedule.create,
    deleteSchedule: Reventless.Schedule.delete,
    queryEngine: Reventless.QueryEngine.operations,
    directive,
  ) =>
    switch directive {
    | PluginExtensionPointSpec.CreateDisconnectSchedule(id, timeout) =>
      await createSchedule({
        name: Spec.environment ++ ("-" ++ id),
        rate: timeout->ScheduleOps.minutesFromNow,
        payload: {
          Message.id,
          meta: Message.generateMeta(~service="Core.Plugin", ~user="Scheduler"),
          command: PluginExtensionPointSpec.DisconnectPlugin,
        }
        ->Message.encodeCommand'(S.string, PluginExtensionPointSpec.commandSchema)
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
      | PluginExtensionPointSpec.Heartbeat(interval) => [
          PublishCommand(id, Aggregate.Heartbeat),
          // Re-create timeout (+2 minute to avoid toggling)
          // 1 minute because Schedules can only be created by minute
          // 1 additional minute to allow additional latency
          Call(callHandler, CreateDisconnectSchedule(id, interval + 2)),
        ]
      | ConnectPlugin(pluginDefinition) =>
        // Validate protocol versions declared by the connecting plugin.
        // On mismatch, emit a ReportIncompatibility command so that an
        // IncompatiblePlugin event is recorded; the connection still proceeds.
        let protocolErrors =
          pluginDefinition.extensionProtocols
          ->Array.flatMap(proto =>
            ReventlessInterop.Compat.validateProtocol(
              ~host=ReventlessInterop.CompatMatrix.corePlugin,
              ~extensionPointName=proto.extensionPointName,
              ~commandVersion=proto.commandVersion,
              ~eventVersion=proto.eventVersion,
            )
          )
        let reportAction =
          if protocolErrors->Array.length > 0 {
            Console.warn3(
              "[Core.Plugin] Protocol version mismatch for plugin",
              pluginDefinition.id,
              protocolErrors,
            )
            [PublishCommand(id, Aggregate.ReportIncompatibility(pluginDefinition))]
          } else {
            []
          }
        Array.concat([PublishCommand(id, Aggregate.Connect(pluginDefinition))], reportAction)
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
            PublishEvent(id, PluginExtensionPointSpec.UnknownPluginDetected),
          ]
        | Connected(pluginDefinition) => [PublishEvent(id, PluginConnected(pluginDefinition))]
        | Reconnected(pluginDefinition) => [PublishEvent(id, PluginReconnected(pluginDefinition))]
        | Disconnected(pluginDefinition) => [PublishEvent(id, PluginDisconnected(pluginDefinition))]
        | Deactivated(pluginDefinition) => [PublishEvent(id, PluginDeactivated(pluginDefinition))]
        | Activated(pluginDefinition) => [PublishEvent(id, PluginActivated(pluginDefinition))]
        | IncompatiblePluginDetected(pluginDefinition) => [
            PublishEvent(id, IncompatiblePlugin(pluginDefinition)),
          ]
        },
    )
  }

  module Mapping = Reventless.ExtensionPointMapping.Make(PluginExtensionPointSpec, Impl)
}
