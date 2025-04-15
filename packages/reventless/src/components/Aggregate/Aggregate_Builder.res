module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  RuntimeEnvironment: Runtime.Environment,
  CommandGeneratorResolvers: CommandGenerator_Adapter.Resolvers
    with type api = Config.api
    and type runtimeParts = RuntimeEnvironment.parts,
  CommandTopicChannel: CommandTopic_Adapter.Channel
    with type runtimeParts = RuntimeEnvironment.parts,
  EventLogStorage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
  EventCollectorChannel: EventCollector_Adapter.Channel,
  AggregateRuntimeBuilder: AggregateRuntime_Builder.T
    with module CommandTopicChannel = CommandTopicChannel
    and module EventCollectorChannel = EventCollectorChannel
    and type runtimeParts = RuntimeEnvironment.parts,
): Aggregate.T => {
  module Spec = Spec

  let addEventMapperFn = (aggregate: Aggregate.component, allEventTopics, queryEngine, ~opts) => {
    module SpecificEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
    module SpecificEventMapper = EventMapper_Builder.Make(
      Spec,
      SpecificEventCollector,
      EventMappings,
      AggregateRuntimeBuilder,
    )

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
      aggregate->AggregateRuntimeBuilder.finish
      {
        ...aggregate->Component.outputs,
        eventMapper: eventMapper->Pulumi.Output.apply(eventMapper =>
          eventMapper->Component.outputs
        ),
      }
    } else {
      aggregate->AggregateRuntimeBuilder.finish
      aggregate->Component.outputs
    }
  }

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let name = name->ComponentType.name(Aggregate.componentType)

    module SpecificEventLog = EventLog_Builder.Make(Spec, EventLogStorage, EventTopicPublisher)
    let eventLog = SpecificEventLog.make(~name, ~opts)

    let commandTopic =
      eventLog
      ->Component.operations
      ->Pulumi.Output.apply(eventLogOps => {
        module SpecificCommandTopic = CommandTopic_Builder.Make(Spec, CommandTopicChannel)
        let commandTopic = SpecificCommandTopic.make(~name, ~opts)

        module AggregateCallback = Aggregate_Callback.Make(
          Spec,
          Behaviour,
          {
            module Spec = Spec
            module EventLog = SpecificEventLog
            let eventLog = eventLogOps
          },
        )
        let handler = SpecificCommandTopic.makeHandler(
          ~commandTopic,
          ~commandsHandler=AggregateCallback.handleCommands,
        )
        let eventLog = eventLog->Component.outputs
        let resources = [eventLog.resources, eventLog.eventTopic.resources]->Array.flat

        commandTopic->AggregateRuntimeBuilder.forCommandTopic(
          ~handler,
          ~connect=SpecificCommandTopic.connect(commandTopic, ~resources, ...)
        )

        commandTopic
      })

    let commandGenerator = commandTopic->Pulumi.Output.flatMap(commandTopic =>
      commandTopic
      ->Component.operations
      ->Pulumi.Output.apply(({publishJsons}) => {
        module SpecificCommandGenerator = CommandGenerator_Builder.Make(
          Config,
          Spec,
          Behaviour,
          CommandGeneratorResolvers,
        )
        let commandGenerator = SpecificCommandGenerator.make(~name, ~opts)
        let resources = (commandTopic->Component.outputs).resources
        commandGenerator->AggregateRuntimeBuilder.forCommandGenerator(
          ~handler=SpecificCommandGenerator.makeHandler(~publishJsons),
          ~connect=SpecificCommandGenerator.connect(commandGenerator, ~resources, ...)
        )
        commandGenerator->Component.outputs
      })
    )

    self->Component.setOperations(
      commandTopic->Pulumi.Output.flatMap(commandTopic =>
        commandTopic
        ->Component.operations
        ->Pulumi.Output.apply(({publishJsons}) => {Aggregate.publishJsons: publishJsons})
      ),
    )
    self->Component.setOutputs({
      Aggregate.name: Spec.name,
      commandGenerator,
      commandTopic: commandTopic->Component.wrappedOutputs,
      eventLog: eventLog->Component.outputs,
      addEventMapper: self->(addEventMapperFn(~opts, ...)),
    })
  }

  let make = (~opts=?): Aggregate.component =>
    Component.make(
      ~componentType=Aggregate.componentType->ComponentType.toString,
      ~name=Spec.name,
      ~construct,
      ~opts,
    )
}
