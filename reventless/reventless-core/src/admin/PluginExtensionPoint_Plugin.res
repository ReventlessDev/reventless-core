open ReventlessInfra.ExtensionPointMapping
open Reventless.Plugin

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec

module type Spec = {
  let runtimeOps: PluginRuntimeOperations.operations
  let environment: string
  let updateApiSchema: option<Reventless.QueryEngine.operations => promise<unit>>
  // Admin-mediated cross-plugin SNS subscription management. Invoked from the
  // DoConnectPlugin / DoDisconnectPlugin directives — the connecting plugin's
  // pluginDefinition is the only argument the admin needs because peer state
  // is read from the Plugin RM at call time. None on the deploy-time EP
  // Lambda (which only handles incoming commands like Heartbeat). Some only
  // on the admin EventCollector entry point.
  let manageSubscriptions: option<
    (Reventless.Plugin.pluginDefinition, [#connect | #disconnect]) => promise<unit>,
  >
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
        Effect.logWarning(
          `ForwardCommand: Couldn't find Plugin with ExtensionPoint ${extensionPointName}`,
        )->Effect.runSync
      | plugins =>
        let plugin = plugins->Array.getUnsafe(0)
        switch plugin->Message.decode(PluginsReadModelSpec.stateSchema) {
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
              Effect.logInfo(
                `ForwardCommand: published command to ${plugin.name} ${extensionPoint.commandTopic}`,
              )->Effect.runSync
            | exception err =>
              let errMsg =
                err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              Effect.logError(
                `PluginExtensionPoint_PluginMapping: Error on publish command: ${errMsg}`,
              )->Effect.runSync
            }

          | None =>
            Effect.logWarning(
              `ForwardCommand: Couldn't find ExtensionPoint ${extensionPointName} in ${plugin.name}`,
            )->Effect.runSync
          }
        | exception err =>
          let errMsg =
            err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
          Effect.logError(`ForwardCommand: Couldn't decode Plugin: ${errMsg}`)->Effect.runSync
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
    | DoConnectPlugin(pluginDef) =>
      switch Spec.manageSubscriptions {
      | Some(fn) => await fn(pluginDef, #connect)
      | None => ()
      }
      switch Spec.updateApiSchema {
      | Some(fn) => await fn(queryEngine)
      | None => ()
      }
    | DoDisconnectPlugin(pluginDef) =>
      switch Spec.manageSubscriptions {
      | Some(fn) => await fn(pluginDef, #disconnect)
      | None => ()
      }
      switch Spec.updateApiSchema {
      | Some(fn) => await fn(queryEngine)
      | None => ()
      }
    }

  module PluginMapping = {
    module ExtensionPoint = PluginExtensionPointSpec
    module Delegate = PluginSpec

    let mapIncomingCommand = (id, cmd, _meta: Message.meta) =>
      switch cmd {
      | PluginExtensionPointSpec.Heartbeat(interval) => [
          PublishCommand(id, Delegate.Heartbeat),
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
          pluginDefinition.extensionProtocols->Array.flatMap(proto =>
            ReventlessInterop.Compat.validateProtocol(
              ~host=ReventlessInterop.CompatMatrix.corePlugin,
              ~extensionPointName=proto.extensionPointName,
              ~commandVersion=proto.commandVersion,
              ~eventVersion=proto.eventVersion,
            )
          )
        let reportAction = if protocolErrors->Array.length > 0 {
          Effect.logWarning(
            `[Core.Plugin] Protocol version mismatch for plugin ${pluginDefinition.id}: ${protocolErrors
              ->JSON.stringifyAny
              ->Option.getOr("[]")}`,
          )->Effect.runSync
          [PublishCommand(id, Delegate.ReportIncompatibility(pluginDefinition))]
        } else {
          []
        }
        Array.concat([PublishCommand(id, Delegate.Connect(pluginDefinition))], reportAction)
      | DisconnectPlugin => [
          PublishCommand(id, Disconnect),
          Call(callHandler, DeleteDisconnectSchedule(id)),
        ]
      | ForwardCommand(forwardCommand) => [Call(callHandler, ForwardCommand(forwardCommand))]
      }

    let mapOutgoingEvent = Some(
      (id, event, _meta, _queryEngine) =>
        switch event {
        | Delegate.UnknownPluginDetected => [
            PublishEvent(id, PluginExtensionPointSpec.UnknownPluginDetected),
          ]
        | Connected(pluginDefinition) => [
            PublishEvent(id, PluginConnected(pluginDefinition)),
            Call(callHandler, DoConnectPlugin(pluginDefinition)),
          ]
        | Reconnected(pluginDefinition) => [
            PublishEvent(id, PluginReconnected(pluginDefinition)),
            Call(callHandler, DoConnectPlugin(pluginDefinition)),
          ]
        | Disconnected(pluginDefinition) => [
            PublishEvent(id, PluginDisconnected(pluginDefinition)),
            Call(callHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | Deactivated(pluginDefinition) => [
            PublishEvent(id, PluginDeactivated(pluginDefinition)),
            Call(callHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | Activated(pluginDefinition) => [PublishEvent(id, PluginActivated(pluginDefinition))]
        | Retired(pluginDefinition) => [
            PublishEvent(id, PluginRetired(pluginDefinition)),
            Call(callHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | IncompatiblePluginDetected(pluginDefinition) => [
            PublishEvent(id, IncompatiblePlugin(pluginDefinition)),
          ]
        | UIFragmentRegistered(_) | UIFragmentUpdated(_) | UIFragmentDeregistered(_) => []
        },
    )
  }

  module Mapping = ReventlessInfra.ExtensionPointMapping.Make(PluginMapping)
}
