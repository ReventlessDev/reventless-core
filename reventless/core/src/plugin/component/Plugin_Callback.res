type jsonEventsHandler = (JSON.t, Reventless.Plugin.pluginDefinition) => promise<unit>
type jsonEventsHandlersByService = dict<array<jsonEventsHandler>>

module type Spec = {
  let pluginDefinition: Reventless.Plugin.pluginDefinition
  let incomingConnectExtensionEventHandlers: jsonEventsHandlersByService
  let outgoingExtensionPointEventHandlers: jsonEventsHandlersByService
  let outgoingExtensionEventHandlers: jsonEventsHandlersByService
  let incomingExtensionEventHandlers: jsonEventsHandlersByService
}

module type T = {
  let handleJsonEvents: EventCollector.jsonEventsHandler
}

module Make = (Spec: Spec): T => {
  let warnedServices = ref(Belt.Set.String.empty)

  let knownServiceNames = () =>
    [
      Spec.incomingConnectExtensionEventHandlers,
      Spec.outgoingExtensionPointEventHandlers,
      Spec.outgoingExtensionEventHandlers,
      Spec.incomingExtensionEventHandlers,
    ]
    ->Array.flatMap(d => d->Dict.keysToArray)
    ->Belt.Set.String.fromArray
    ->Belt.Set.String.toArray

  // A plugin's own DCB EventLog feeds Plugin_Callback through the shared
  // EventCollector, but the events terminate at intra-plugin SVS/RM consumers
  // via a different path. When no outgoing EP/Extension wants them here, that
  // is normal — silence the warning rather than misleadingly suggesting a
  // Delegate.name mismatch.
  let ownDcbEventLogServiceName = `${Spec.pluginDefinition.name}DcbEventLog`

  let warnUnmatchedServiceOnce = (~id, ~serviceName) =>
    if (
      serviceName == ownDcbEventLogServiceName ||
        warnedServices.contents->Belt.Set.String.has(serviceName)
    ) {
      Effect.succeed()
    } else {
      warnedServices := warnedServices.contents->Belt.Set.String.add(serviceName)
      let known = knownServiceNames()->Array.join(", ")
      EffectLogger.logWarn(
        ~comp=`Plugin(${id})`,
        `incoming event has service="${serviceName}" but no handler is registered for it — known services: [${known}]. Likely cause: an ExtensionPointMapping/Extension Delegate.name does not match the source's serviceName (DCB sources use "<plugin>DcbEventLog").`,
      )
    }

  let handleEventEffect = (eventJson', jsonEventsHandlersByService) =>
    eventJson'
    ->Message.serviceNameOfMsg
    ->Option.flatMap(serviceName => jsonEventsHandlersByService->Dict.get(serviceName))
    ->Option.mapOr(Effect.succeed(), jsonEventsHandlers =>
      Effect.all(
        jsonEventsHandlers->Array.map(jsonEventsHandler =>
          Effect.promise(() => jsonEventsHandler(eventJson', Spec.pluginDefinition))
        ),
        {"concurrency": "unbounded"},
      )->Effect.map(_ => ())
    )

  let handleJsonEvents: EventCollector.jsonEventsHandler = stream =>
    stream
    ->Stream.mapEffect(eventJson' => {
      let id = Spec.pluginDefinition.id
      eventJson'
      ->Message.serviceNameOfMsg
      ->Option.mapOr(Effect.succeed(), serviceName => {
        let isHandled =
          Spec.incomingConnectExtensionEventHandlers->Dict.get(serviceName)->Option.isSome ||
          Spec.outgoingExtensionPointEventHandlers->Dict.get(serviceName)->Option.isSome ||
          Spec.outgoingExtensionEventHandlers->Dict.get(serviceName)->Option.isSome ||
          Spec.incomingExtensionEventHandlers->Dict.get(serviceName)->Option.isSome
        if isHandled {
          EffectLogger.logInfo(~comp=`Plugin(${id})`, `incoming event: ${LogFormat.eventSummary(eventJson')}`)
          ->Effect.zipRight(
            handleEventEffect(eventJson', Spec.incomingConnectExtensionEventHandlers)
            ->Effect.zipRight(
              Effect.all(
                [
                  handleEventEffect(eventJson', Spec.outgoingExtensionPointEventHandlers),
                  handleEventEffect(eventJson', Spec.outgoingExtensionEventHandlers),
                  handleEventEffect(eventJson', Spec.incomingExtensionEventHandlers),
                ],
                {"concurrency": "unbounded"},
              )->Effect.map(_ => ())
            )
          )
        } else {
          warnUnmatchedServiceOnce(~id, ~serviceName)
        }
      })
    })
    ->Stream.runDrain
}
