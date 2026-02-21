module Make = (
  Spec: ReventlessSpec.Aggregate.Spec,
  Behavior: Behavior.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandGeneratorResolvers: CommandGenerator_Adapter.Resolvers
    with type runtimeParts = RuntimeEnvironment.parts,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventLogStorage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
  EventCollectorChannel: EventCollector_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  AggregateRuntimeBuilder: AggregateRuntime_Builder.T
    with module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
): (Aggregate.T with type api = CommandGeneratorResolvers.api and type component = Aggregate.component) => {
  module Spec = Spec
  module AggregateRuntimeBuilder = AggregateRuntimeBuilder

  type api = CommandGeneratorResolvers.api
  type component = Aggregate.component

  module SpecificEventLog = EventLog_Builder.Make(Spec, EventLogStorage, EventTopicPublisher)
  module SpecificCommandTopic = CommandTopic_Builder.Make(Spec, CommandTopicChannel)
  module SpecificCommandGenerator = CommandGenerator_Builder.Make(
    Spec,
    Behavior,
    CommandGeneratorResolvers,
  )
  module SpecificEventCollector = EventCollector_Builder.Make(
    RuntimeEnvironment,
    EventCollectorChannel,
  )
  module SpecificEventMapper = EventMapper_Builder.Make(
    Spec,
    SpecificEventCollector,
    EventMappings,
    AggregateRuntimeBuilder,
  )

  let addEventMapperFn = (aggregate: Aggregate.component, allEventTopics, queryEngine, ~opts) => {
    if EventMappings.mappings->Array.length > 0 {
      let eventMapper =
        (aggregate->Component.operations, (aggregate->Component.outputs).commandTopic)
        ->Pulumi.Output.all2
        ->Pulumi.Output.apply((({publishJsons}, commandTopic)) =>
          SpecificEventMapper.make(
            ~name=Spec.name->ComponentType.name(Aggregate.componentType),
            ~allEventTopics,
            ~queryEngine,
            ~publishJsons,
            ~resources=commandTopic.resources,
            ~opts,
          )
        )
      {
        ...aggregate->Component.outputs,
        eventMapper: eventMapper->Pulumi.Output.apply(eventMapper =>
          eventMapper->Component.outputs
        ),
      }
    } else {
      aggregate->Component.outputs
    }
  }

  let createCommandTopic = (eventLog: SpecificEventLog.component, name, opts) =>
    eventLog
    ->Component.operations
    ->Pulumi.Output.apply(eventLogOps => {
      module AggregateCallback = Aggregate_Callback.Make(
        Spec,
        Behavior,
        {
          module Spec = Spec
          module EventLog = SpecificEventLog
          let eventLog = eventLogOps
        },
      )
      let commandTopic = SpecificCommandTopic.make(~name, ~opts)
      let handler = SpecificCommandTopic.makeHandler(
        ~commandTopic,
        ~commandsHandler=AggregateCallback.handleCommands,
      )
      let eventLog = eventLog->Component.outputs
      let resources = [eventLog.resources, eventLog.eventTopic.resources]->Array.flat
      commandTopic->AggregateRuntimeBuilder.forCommandTopic(
        ~handler,
        ~connect=SpecificCommandTopic.connect(commandTopic, ~resources, ...),
      )
      commandTopic
    })

  let createCommandGenerator = (
    commandTopic: Pulumi.Output.t<SpecificCommandTopic.component>,
    ~api: CommandGeneratorResolvers.api,
    name,
    opts,
  ) =>
    commandTopic->Pulumi.Output.flatMap(commandTopic =>
      commandTopic
      ->Component.operations
      ->Pulumi.Output.apply(({publishJsons}) => {
        let commandGenerator = SpecificCommandGenerator.make(~name, ~opts)
        let resources = (commandTopic->Component.outputs).resources
        commandGenerator->AggregateRuntimeBuilder.forCommandGenerator(
          ~handler=SpecificCommandGenerator.makeHandler(~publishJsons),
          ~connect=SpecificCommandGenerator.connect(commandGenerator, ~api, ~resources, ...),
        )
        commandGenerator
      })
    )

  let construct = (~api: CommandGeneratorResolvers.api, self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(Aggregate.componentType)

    let eventLog = SpecificEventLog.make(~name, ~opts)
    let commandTopic = eventLog->createCommandTopic(name, opts)
    let commandGenerator = commandTopic->createCommandGenerator(~api, name, opts)

    self->Component.setOperations(
      commandTopic->Pulumi.Output.flatMap(commandTopic =>
        commandTopic
        ->Component.operations
        ->Pulumi.Output.apply(({publishJsons}) => {
          let ops: Aggregate.operations = {publishJsons: publishJsons}
          ops
        })
      ),
    )
    let aggOutputs: Aggregate.outputs = {
      name: Spec.name,
      commandGenerator: commandGenerator->Component.wrappedOutputs,
      commandTopic: commandTopic->Component.wrappedOutputs,
      eventLog: eventLog->Component.outputs,
      addEventMapper: self->addEventMapperFn(~opts, ...),
    }
    self->Component.setOutputs(aggOutputs)
  }

  let make = (~api: CommandGeneratorResolvers.api, ~opts=?): Aggregate.component =>
    Component.make(
      ~componentType=Aggregate.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct=construct(~api, ...),
      ~opts,
    )

  let outputs = Component.outputs
  let operations = Component.operations
  let finish = () => AggregateRuntimeBuilder.finish()
}
