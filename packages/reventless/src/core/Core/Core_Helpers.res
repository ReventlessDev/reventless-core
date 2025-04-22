let addEventMapperFns = Plugin_Helpers.addEventMapperFns
let aggregateResources = Plugin_Helpers.aggregateResources
let publishToAggregates = Plugin_Helpers.publishToAggregates

let createAggregatesWithoutEventMappers = Plugin_Helpers.createAggregatesWithoutEventMappers
let addEventMappers = Plugin_Helpers.addEventMappers
let createReadModels = Plugin_Helpers.createReadModels
let createExtensionPoints = Plugin_Helpers.createExtensionPoints

let createResolvers = allQueryDbs =>
  allQueryDbs
  ->QueryDb.allResolversMakers
  ->Array.map(resolverMaker => resolverMaker(allQueryDbs))
  ->Array.flat

module MakeEventCollectorHelper = (
  RuntimeEnvironment: Runtime.Environment,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  CoreRuntimeBuilder: PluginRuntime_Builder.T
    with module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
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
    ~extensionPointsOutgoingEventHandlers,
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
      let fakePluginDefinition: ReventlessSpec.Plugin.pluginDefinition = {
        id: "Core@FAKE",
        name: "Core",
        version: "FAKE",
        extensionPoints: [],
        extensions: [],
        eventCollector: "NOT-SET",
      }

      module Callback = Core_Callback.Make({
        let pluginDefinition = fakePluginDefinition
        let outgoingExtensionPointEventHandlers = extensionPointsOutgoingEventHandlers
      })
      let handler = CoreEventCollector.makeHandler(
        ~eventCollector,
        ~eventsHandler=Callback.handleJsonEvents,
      )
      eventCollector->CoreRuntimeBuilder.forPluginEventCollector(~handler, ~eventTopics, ~resources)
    })
  }
}
