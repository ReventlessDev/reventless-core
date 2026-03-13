include Builder_Helpers

module MakeEventCollectorHelper = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel,
) => {
  module CoreEventCollector = EventCollector_Builder.Make(RuntimeEnvironment, EventCollectorChannel)
  let make = (~name, ~eventTopics, ~opts) => {
    let eventCollector = CoreEventCollector.make(~name, ~eventTopics, ~opts)
    let eventCollectorOutputs = eventCollector->Component.outputs
    (eventCollector, eventCollectorOutputs)
  }

  let connect = (
    ~eventCollector: EventCollector.component,
    ~eventTopics: EventTopic.allOutputs,
    ~extensionPointsOutputs: array<ExtensionPoint.outputs>,
    ~extensionPointsOutgoingJsonEventsHandlers,
  ) => {
    let resources =
      extensionPointsOutputs
      ->Array.map(extensionPoint => extensionPoint.eventTopic)
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(eventTopics =>
        eventTopics
        ->Array.map(eventTopic => eventTopic.resources)
        ->Array.flat
      )

    resources->Pulumi.Output.apply(resources => {
      let fakePluginDefinition: Reventless.Plugin.pluginDefinition = {
        id: "Core@FAKE",
        name: "Core",
        version: "FAKE",
        extensionPoints: [],
        extensions: [],
        eventCollector: "NOT-SET",
        extensionProtocols: [],
        apiSchemaFragment: None,
      }

      module Callback = Core_Callback.Make({
        let pluginDefinition = fakePluginDefinition
        let outgoingExtensionPointJsonEventsHandlers = extensionPointsOutgoingJsonEventsHandlers
      })
      let handler = CoreEventCollector.makeHandler(
        ~eventCollector,
        ~jsonEventsHandler=Callback.handleJsonEvents,
      )
      eventCollector->CoreRuntimeBuilder.forPluginEventCollector(~handler, ~eventTopics, ~resources)
    })
  }
}
