module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec
module ExtensionMapping = ReventlessInfra.ExtensionMapping

module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  let extensionPointsOutputs: array<ReventlessInterop.ExtensionPoint.resolvedOutputs>
  let extensionsOutputs: array<Extension.outputs>
  let runtimeOps: PluginRuntimeOperations.operations
  let resourceNaming: ReventlessInfra.ResourceNaming.operations
}

module Make = (Spec: Spec) => {
  let log = Logger.fromEnv()

  let subscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    let eventTopicName = eventTopic->Spec.resourceNaming.urnName
    let eventCollectorName = eventCollector->Spec.resourceNaming.urnName
    let _sid = (extensionPointName ++ ("-" ++ pluginId))->Spec.resourceNaming.validateName

    log.debug(~comp="Admin", `trying ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`)
    switch await Spec.runtimeOps.topicSubscription.subscribeChannelToTopic(
      ~channelId=eventCollector,
      ~topicId=eventTopic,
    ) {
    | _ =>
      log.info(~comp="Admin", `${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`)
    | exception JsExn(e) =>
      let msg = e->JsExn.message->Option.getOr("unknown")
      log.error(~comp="Admin", `${action} failed: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}): ${msg}`)
    }
  }

  let unsubscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    let eventTopicName = eventTopic->Spec.resourceNaming.urnName
    let eventCollectorName = eventCollector->Spec.resourceNaming.urnName
    let _sid = (extensionPointName ++ ("-" ++ pluginId))->Spec.resourceNaming.validateName

    log.debug(~comp="Admin", `trying ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`)
    switch await Spec.runtimeOps.topicSubscription.unsubscribeChannelFromTopic(
      ~channelId=eventCollector,
      ~topicId=eventTopic,
    ) {
    | _ =>
      log.info(~comp="Admin", `${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`)
    | exception JsExn(e) =>
      let msg = e->JsExn.message->Option.getOr("unknown")
      log.error(~comp="Admin", `${action} failed: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}): ${msg}`)
    }
  }

  let callHandler = async command => {
    let pluginDefinition = Spec.pluginDefinition
    let id = pluginDefinition.id

    switch command {
    | PluginExtensionPointSpec.DoConnectPlugin({
        id: otherPluginId,
        extensionPoints: otherPluginExtensionPoints,
        extensions: otherPluginExtensions,
        eventCollector: otherPluginEventCollector,
      }) =>
      /* Current Plugin received `PluginConnected`:
       *  this means: current plugin was already deployed before and received plugin just has been deployed
       * - connectToExtensionPoints: if the newly deployed (received) plugin contains extensionpoints
       *    the current plugin relies on: connect current plugin to received plugin extension point's eventTopic
       * - if the newly deployed (received) plugin contains extensions the current plugin holds an extensionpoint for:
       *    connect received extensions to current plugin's extension point
       */
      let connectToExtensionPoints =
        otherPluginExtensionPoints
        ->Message.log("otherPluginExtensionPoints:")
        ->Array.filterMap(({name: extensionPointName, eventTopic}) =>
          Spec.extensionsOutputs
          ->Array.filter((extension: Extension.outputs) =>
            extension.extensionPointName == extensionPointName
          )
          ->Message.log("matching Extensions:")
          ->Array.length > 0
            ? Some(
                subscribe(
                  "connectToExtensionPoints",
                  extensionPointName,
                  eventTopic,
                  id,
                  pluginDefinition.eventCollector,
                ),
              )
            : None
        )

      let connectToExtensions =
        Spec.extensionPointsOutputs
        ->Message.log("extensionPoints:")
        ->Array.filterMap(extensionPoint =>
          otherPluginExtensions
          ->Array.filter(({extensionPointName}) => extensionPoint.name == extensionPointName)
          ->Message.log("matching otherPluginExtensions:")
          ->Array.length > 0
            ? Some(
                subscribe(
                  "connectToExtensions",
                  extensionPoint.name,
                  (extensionPoint.eventTopic.resources->Array.getUnsafe(0)).id, // FIXME
                  otherPluginId,
                  otherPluginEventCollector,
                ),
              )
            : None
        )

      await connectToExtensionPoints
      ->Array.concat(connectToExtensions)
      ->Promise.all
      ->Util.Promise.toUnit

    | DoDisconnectPlugin({
        id: pluginId,
        extensionPoints: pluginExtensionPoints,
        extensions: pluginExtensions,
        eventCollector: pluginEventCollector,
      }) =>
      let disconnectFromExtensionPoints = pluginExtensionPoints->Array.filterMap(({
        name: extensionPointName,
        eventTopic,
      }) =>
        Spec.extensionsOutputs
        ->Array.filter(extension => extension.extensionPointName == extensionPointName)
        ->Array.length > 0
          ? Some(
              unsubscribe(
                "disconnectFromExtensionPoints",
                extensionPointName,
                eventTopic,
                id,
                pluginDefinition.eventCollector,
              ),
            )
          : None
      )

      let disconnectFromExtensions = Spec.extensionPointsOutputs->Array.filterMap(extensionPoint =>
        pluginExtensions
        ->Array.filter(({extensionPointName}) => extensionPoint.name == extensionPointName)
        ->Array.length > 0
          ? Some(
              unsubscribe(
                "disconnectFromExtensions",
                extensionPoint.name,
                (extensionPoint.eventTopic.resources->Array.getUnsafe(0)).id, // FIXME
                pluginId,
                pluginEventCollector,
              ),
            )
          : None
      )

      await disconnectFromExtensionPoints
      ->Array.concat(disconnectFromExtensions)
      ->Promise.all
      ->Util.Promise.toUnit

    | _ => ()
    }
  }

  module ConnectPluginMapping = ExtensionMapping.Make(
    PluginExtensionPointSpec,
    {
      module Delegate = ReventlessInfra.ExtensionMapping.NoDelegate

      let mapIncomingEvent: ReventlessInfra.ExtensionMapping.mapIncomingEvent<
        PluginExtensionPointSpec.event,
        Delegate.command,
        PluginExtensionPointSpec.command,
        PluginExtensionPointSpec.directive,
      > = (pluginId, event, _meta, _pluginDef, _queryEngine) => {
        let pluginDefinition = Spec.pluginDefinition
        let id = pluginDefinition.id

        switch event {
        | PluginExtensionPointSpec.UnknownPluginDetected if pluginId == id => [
            PublishExtensionPointCommand(
              id,
              PluginExtensionPointSpec.ConnectPlugin(pluginDefinition),
            ),
          ]
        | PluginConnected(pluginDef)
        | PluginReconnected(pluginDef) if pluginId != id => [
            Call(callHandler, DoConnectPlugin(pluginDef)),
          ]
        | PluginDeactivated(pluginDef) if pluginId != id => [
            Call(callHandler, DoDisconnectPlugin(pluginDef)),
          ]
        // don't disconnect because a newer version might be already connected
        // if the old version gets destroyed, then the subscription is also destroyed
        | PluginDisconnected(_) => []
        | _ => []
        }
      }

      let mapOutgoingEvent = None
    },
  )

  module ConnectPluginMappings = {
    module Spec = PluginExtensionPointSpec
    module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
    let name = "Connect"
    let moduleUrl: string = %raw(`import.meta.url`)
    let mappings: array<module(Mapping)> = [module(ConnectPluginMapping)]
  }

  include Extension_Builder.Make(PluginExtensionPointSpec, ConnectPluginMappings)
}
