module type Spec = {
  let pluginDefinition: ReventlessSpec.Plugin.pluginDefinition
  let extensionPointsOutputs: array<ExtensionPoint.unwrappedOutputs>
  let extensionsOutputs: array<Extension.outputs>
}

module Make = (Spec: Spec) => {
  let subscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    let eventTopicName = eventTopic->AWS.arn2Name
    let eventCollectorName = eventCollector->AWS.arn2Name
    let _sid = (extensionPointName ++ ("-" ++ pluginId))->AWS.validateName

    Js.log(
      `Trying to ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
    )
    switch await AwsSdk.SNS.subscribeQueueToTopic(eventCollector, eventTopic) {
    | _ =>
      Js.log(
        `Successful ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
      )
    | exception Js.Exn.Error(e) =>
      Js.log2(
        `Could not ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}):`,
        e,
      )
    }
  }

  let unsubscribe = async (action, extensionPointName, eventTopic, pluginId, eventCollector) => {
    let eventTopicName = eventTopic->AWS.arn2Name
    let eventCollectorName = eventCollector->AWS.arn2Name
    let _sid = (extensionPointName ++ ("-" ++ pluginId))->AWS.validateName

    Js.log(
      `Trying to ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
    )
    switch await AwsSdk.SNS.unsubscribeQueueFromTopic(eventCollector, eventTopic) {
    | _ =>
      Js.log(
        `Success: ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName})`,
      )
    | exception Js.Exn.Error(e) =>
      Js.log2(
        `Could not ${action}: ${extensionPointName}->${pluginId} (${eventTopicName}->${eventCollectorName}):`,
        e,
      )
    }
  }

  let callHandler = async command => {
    let pluginDefinition = Spec.pluginDefinition
    let id = pluginDefinition.id

    switch command {
    | ReventlessSpec.PluginExtensionPointSpec.DoConnectPlugin({
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
      ->Js.Promise.all
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
      ->Js.Promise.all
      ->Util.Promise.toUnit

    | _ => ()
    }
  }

  module ConnectPluginMapping = ExtensionMapping.Make(
    ReventlessSpec.PluginExtensionPointSpec,
    {
      module Aggregate = ReventlessSpec.ExtensionMapping.NoAggregate

      let mapIncomingEvent: ReventlessSpec.ExtensionMapping.mapIncomingEvent<
        ReventlessSpec.PluginExtensionPointSpec.event,
        Aggregate.command,
        ReventlessSpec.PluginExtensionPointSpec.command,
        ReventlessSpec.PluginExtensionPointSpec.callCommand,
      > = (pluginId, event, _meta, _pluginDef, _queryEngine) => {
        let pluginDefinition = Spec.pluginDefinition
        let id = pluginDefinition.id

        switch event {
        | ReventlessSpec.PluginExtensionPointSpec.UnknownPluginDetected if pluginId == id => [
            PublishExtensionPointCommand(
              id,
              ReventlessSpec.PluginExtensionPointSpec.ConnectPlugin(pluginDefinition),
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
    module Spec = ReventlessSpec.PluginExtensionPointSpec
    module type Mapping = ExtensionMapping.T with module ExtensionPoint := Spec
    let name = "Connect"
    let mappings: array<module(Mapping)> = [module(ConnectPluginMapping)]
  }

  include Extension_Builder.Make(ReventlessSpec.PluginExtensionPointSpec, ConnectPluginMappings)
}
