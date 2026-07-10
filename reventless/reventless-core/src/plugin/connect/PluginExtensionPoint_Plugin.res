@@reventless.spec

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
        EffectLogger.logWarn(
          ~comp="Core.Plugin",
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
              EffectLogger.logInfo(
                ~comp="Core.Plugin",
                `ForwardCommand: published command to ${plugin.name} ${extensionPoint.commandTopic}`,
              )->Effect.runSync
            | exception err =>
              let errMsg =
                err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
              EffectLogger.logError(
                ~comp="Core.Plugin",
                `ForwardCommand: Error on publish command: ${errMsg}`,
              )->Effect.runSync
            }

          | None =>
            EffectLogger.logWarn(
              ~comp="Core.Plugin",
              `ForwardCommand: Couldn't find ExtensionPoint ${extensionPointName} in ${plugin.name}`,
            )->Effect.runSync
          }
        | exception err =>
          let errMsg =
            err->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
          EffectLogger.logError(~comp="Core.Plugin", `ForwardCommand: Couldn't decode Plugin: ${errMsg}`)->Effect.runSync
        }
      }
    }

  let directiveHandler = async (
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

    // Unused by ExtensionPointMapping.Make (it reads name/Delegate/map* only);
    // present solely to satisfy the input module type. The actually-consumed
    // dynamic-import specifier is the file-level `moduleUrl` (@@reventless.spec
    // injected, move-safe) referenced from Plugin_Helpers.
    let moduleUrl = PluginExtensionPointSpec.moduleUrl

    // The Plugin aggregate is keyed by plugin **name**; the EP transport id is
    // `name@version` (Approach 1). Translate at this boundary: route Delegate
    // commands to `Plugin.name(id)` and carry the version (from the id) in the
    // command. The EP keeps its per-version disconnect schedule keyed by the
    // full `id` — liveness stays scheduler-driven, the aggregate never reads time.
    let mapIncomingCommand = (id, cmd, _meta: Message.meta) =>
      switch cmd {
      | PluginExtensionPointSpec.Heartbeat(interval) => [
          PublishCommand(Plugin.name(id), Delegate.Heartbeat(Plugin.version(id))),
          // Re-create timeout (+2 minute to avoid toggling)
          // 1 minute because Schedules can only be created by minute
          // 1 additional minute to allow additional latency
          HandleDirective(directiveHandler, CreateDisconnectSchedule(id, interval + 2)),
        ]
      | RedetectPlugin(interval) => [
          // Deploy-time re-detect: drive Redetect (not Heartbeat) so an already-connected
          // version re-runs the handshake and refreshes its stored definition. Still
          // re-arm the disconnect schedule exactly like a heartbeat so liveness tracking
          // continues from the deploy moment.
          PublishCommand(Plugin.name(id), Delegate.Redetect(Plugin.version(id))),
          HandleDirective(directiveHandler, CreateDisconnectSchedule(id, interval + 2)),
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
          EffectLogger.logWarn(
            ~comp="Core.Plugin",
            `Protocol version mismatch for plugin ${pluginDefinition.id}: ${protocolErrors
              ->JSON.stringifyAny
              ->Option.getOr("[]")}`,
          )->Effect.runSync
          [PublishCommand(Plugin.name(id), Delegate.ReportIncompatibility(pluginDefinition))]
        } else {
          []
        }
        Array.concat(
          [PublishCommand(Plugin.name(id), Delegate.Connect(pluginDefinition))],
          reportAction,
        )
      | DisconnectPlugin => [
          PublishCommand(Plugin.name(id), Delegate.Disconnect(Plugin.version(id))),
          HandleDirective(directiveHandler, DeleteDisconnectSchedule(id)),
        ]
      | ForwardCommand(forwardCommand) => [HandleDirective(directiveHandler, ForwardCommand(forwardCommand))]
      }

    let mapOutgoingEvent = Some(
      (id, event, _meta, _queryEngine) =>
        switch event {
        // `id` is the Plugin aggregate id (= name). VersionDetected re-builds the
        // `name@version` id so the matching version's ConnectExtension (which keys
        // on its own pluginDefinition.id) answers the handshake. Events carrying a
        // definition publish with `def.id` (= name@version), preserving the prior
        // cross-plugin wire id.
        | Delegate.VersionDetected(version) => [
            PublishEvent(Plugin.makeId(id, version), PluginExtensionPointSpec.UnknownPluginDetected),
          ]
        | VersionConnected(pluginDefinition)
        | VersionPromoted(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, PluginConnected(pluginDefinition)),
            HandleDirective(directiveHandler, DoConnectPlugin(pluginDefinition)),
          ]
        // Supersession shares the name-keyed infra with the new current version
        // (whose VersionConnected already re-stitched the schema); no EP action.
        | VersionSuperseded(_) => []
        | VersionDisconnected(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, PluginDisconnected(pluginDefinition)),
            HandleDirective(directiveHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | VersionDeactivated(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, PluginDeactivated(pluginDefinition)),
            HandleDirective(directiveHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | VersionActivated(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, PluginActivated(pluginDefinition)),
          ]
        | VersionRetired(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, PluginRetired(pluginDefinition)),
            HandleDirective(directiveHandler, DoDisconnectPlugin(pluginDefinition)),
          ]
        | IncompatiblePluginDetected(pluginDefinition) => [
            PublishEvent(pluginDefinition.id, IncompatiblePlugin(pluginDefinition)),
          ]
        | UIFragmentRegistered(_) | UIFragmentUpdated(_) | UIFragmentDeregistered(_) => []
        },
    )
  }

  module Mapping = ReventlessInfra.ExtensionPointMapping.Make(PluginMapping)
}
