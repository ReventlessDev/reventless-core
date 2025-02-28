module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  CommandGeneratorResolvers: CommandGenerator_Adapter.Resolvers with type api := Config.api,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventLogStorage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic_Adapter.Publisher,
  EventCollectorChannel: EventCollector_Adapter.Channel,
  RuntimeEnvironment: Runtime.Environment,
): Aggregate.T => {
  module Spec = Spec

  let addEventMapperFn = (component: Aggregate.component, allEventTopics, queryEngine, ~opts) => {
    module SpecificEventCollector = EventCollector_Builder.Make(EventCollectorChannel)
    module SpecificEventMapper = EventMapper_Builder.Make(
      Spec,
      SpecificEventCollector,
      EventMappings,
      RuntimeEnvironment,
    )

    let outputs = component->Component.outputs
    if EventMappings.mappings->Belt.Array.length > 0 {
      let eventMapper =
        component
        ->Component.operations
        ->Pulumi.Output.apply(({publishJsons}) =>
          SpecificEventMapper.make(~allEventTopics, ~queryEngine, ~publishJsons, ~opts)
        )
      {
        ...outputs,
        eventMapper: eventMapper->Pulumi.Output.apply(eventMapper =>
          eventMapper->Component.outputs
        ),
      }
    } else {
      outputs
    }
  }

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}
    let childName = name->ComponentType.name(Aggregate.componentType)

    module SpecificEventLog = EventLog_Builder.Make(Spec, EventLogStorage, EventTopicPublisher)
    let eventLog = SpecificEventLog.make(~name=childName, ~opts)

    let commandTopic =
      eventLog
      ->Component.operations
      ->Pulumi.Output.apply(eventLogOps => {
        module SpecificCommandTopic = CommandTopic_Builder.Make(Spec, CommandTopicChannel)
        let channel = SpecificCommandTopic.makeChannel(~name=childName, ~opts)
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
          ~channel,
          ~commandsHandler=AggregateCallback.handleCommands,
        )
        let runtime = RuntimeEnvironment.make(~name=childName, ~handler, ~opts)

        SpecificCommandTopic.make(~name=childName, ~channel, ~runtime, ~opts)
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
        let runtime = RuntimeEnvironment.make(
          ~name=childName,
          ~handler=SpecificCommandGenerator.makeHandler(~publishJsons),
          ~opts,
        )
        SpecificCommandGenerator.make(~name=childName, ~runtime, ~opts)->Component.outputs
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
      Aggregate.name,
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
