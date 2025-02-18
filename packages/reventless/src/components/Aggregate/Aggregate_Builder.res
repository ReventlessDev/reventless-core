module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  CommandGeneratorResolvers: CommandGenerator.Adapter.Resolvers with type api := Config.api,
  CommandTopicChannel: CommandTopic_Adapter.Channel,
  EventLogStorage: EventLog_Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
  EventCollectorConnector: EventCollector.Adapter.Connector,
  RuntimeEnvironment: Runtime.Environment,
): Aggregate.T => {
  module Spec = Spec
  module SpecificCommandGenerator = CommandGenerator.Make(
    Config,
    Spec,
    Behaviour,
    CommandGeneratorResolvers,
  )

  let addEventMapperFn = (component: Aggregate.component, allEventTopics, queryEngine, ~opts) => {
    module SpecificEventCollector = EventCollector.Make(EventCollectorConnector)
    module SpecificEventMapper = EventMapper.Make(Spec, SpecificEventCollector, EventMappings)

    let eventMapper =
      EventMappings.mappings->Belt.Array.length > 0
        ? Some(
            component
            ->Component.operations
            ->Pulumi.Output.apply(({publishJsons}) =>
              SpecificEventMapper.make(~allEventTopics, ~queryEngine, ~publishJsons, ~opts)
            ),
          )
        : None
    Js.log2("eventMapper1:", eventMapper)

    {
      ...component->Component.extractOutputs,
      eventMapper: ?eventMapper->Belt.Option.map(eventMapper => {
        Js.log2("eventMapper2:", eventMapper)
        eventMapper->Pulumi.Output.apply(eventMapper => {
          Js.log2("eventMapper3:", eventMapper)
          eventMapper->Component.extractOutputs
        })
      }),
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
        module Ops = {
          module Spec = Spec
          module EventLog = SpecificEventLog
          let eventLog = eventLogOps
        }
        module SpecificCommandTopic = CommandTopic_Builder.Make(
          Spec,
          CommandTopicChannel,
          RuntimeEnvironment,
        )
        let channel = SpecificCommandTopic.makeChannel(~name=childName, ~opts)
        module Runtime = Aggregate_Runtime.Make(Spec, Behaviour, Ops)
        SpecificCommandTopic.make(
          ~name=childName,
          ~channel,
          ~commandsHandler=Runtime.handleCommands,
          ~opts,
        )
      })

    let commandGenerator = commandTopic->Pulumi.Output.flatMap(commandTopic =>
      commandTopic
      ->Component.operations
      ->Pulumi.Output.apply(({publishJsons}) => {
        SpecificCommandGenerator.make(
          ~name=childName,
          ~publishJsons,
          ~opts,
        )->Component.extractOutputs
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
      commandTopic: commandTopic->Component.extractWrappedOutputs,
      eventLog: eventLog->Component.extractOutputs,
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
