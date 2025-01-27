let componentType = ComponentType.Aggregate

type outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: ReventlessSpec.CommandTopic.outputs,
  eventLog: EventLog.outputs,
  eventMapper?: EventMapper.outputs,
}
type allOutputs = Js.Dict.t<outputs>

let allEventTopics = allAggregates =>
  Js.Dict.map(aggregate => aggregate.eventLog.eventTopic, allAggregates)

let filterEventTopics = (allAggregates, aggregateNames) =>
  aggregateNames
  ->Belt.Set.String.toArray
  ->Belt.Array.keepMap(aggregateName =>
    allAggregates
    ->Js.Dict.get(aggregateName)
    ->Belt.Option.map(aggregateOutput => (aggregateName, aggregateOutput.eventLog.eventTopic))
  )
  ->Js.Dict.fromArray

type name = string

type t
type component = ReventlessSpec.Component.t<t, outputs>

type addEventMapper = (
  ReventlessSpec.EventTopic.allOutputs,
  ReventlessSpec.QueryEngine.t,
) => outputs

module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec

  let make: (~opts: Pulumi.ComponentResource.options=?) => component

  let publishJsons: component => ReventlessSpec.CommandTopic.publishJsons
  let addEventMapper: component => addEventMapper
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  EventMappings: EventMapper.Mappings with module Target := Spec,
  CommandGeneratorResolvers: CommandGenerator.Adapter.Resolvers with type api := Config.api,
  CommandTopicConnector: CommandTopic.Adapter.Connector,
  EventLogStorage: EventLog.Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
  EventCollectorConnector: EventCollector.Adapter.Connector,
): (T with module Spec = Spec) => {
  module Spec = Spec

  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  @set
  external setPublishJsons: (component, ReventlessSpec.CommandTopic.publishJsons) => unit =
    "publishJsons"
  @get
  external publishJsons: component => ReventlessSpec.CommandTopic.publishJsons = "publishJsons"

  @set
  external setAddEventMapper: (component, addEventMapper) => unit = "addEventMapper"
  @get
  external addEventMapper: component => addEventMapper = "addEventMapper"

  module CommandGenerator = CommandGenerator.Make(
    Config,
    Spec,
    Behaviour,
    CommandGeneratorResolvers,
  )
  module CommandTopic = CommandTopic.Make(Spec, CommandTopicConnector)
  module EventLog = EventLog.Make(Spec, EventLogStorage, EventTopicPublisher)

  let addEventMapperFn = (component, allEventTopics, queryEngine, ~opts) => {
    module EventCollector = EventCollector.Make(EventCollectorConnector)
    module EventMapper = EventMapper.Make(Spec, EventCollector, EventMappings)

    let eventMapper =
      EventMappings.mappings->Belt.Array.length > 0
        ? Some(
            EventMapper.make(
              ~allEventTopics,
              ~queryEngine,
              ~publishJsons=component->publishJsons,
              ~opts,
            ),
          )
        : None
    {
      ...component->Component.extractOutputs,
      eventMapper: ?eventMapper->Belt.Option.map(eventMapper =>
        eventMapper->Component.extractOutputs
      ),
    }
  }

  let construct = (self, name) => {
    let opts = {Pulumi.ComponentResource.parent: self->Component.toPulumiResource}

    let childName = name->ComponentType.name(componentType)

    let eventLog = EventLog.make(~name=childName, ~opts)

    module Runtime = Aggregate_Runtime.Make(Spec, Behaviour)

    let commandTopic = CommandTopic.make(
      ~name=childName,
      ~commandsHandler=Runtime.handleCommands(
        eventLog->EventLog.append,
        eventLog->EventLog.replay,
        ...
      ),
      ~opts,
    )
    let commandTopicOutputs = commandTopic->Component.extractOutputs

    let commandGenerator = commandTopicOutputs.publishJsons->Pulumi.Output.apply(publishJsons => {
      self->setPublishJsons(publishJsons)
      self->setAddEventMapper(self->(addEventMapperFn(~opts, ...)))

      CommandGenerator.make(~name=childName, ~publishJsons, ~opts)->Component.extractOutputs
    })

    self->setOutputs({
      name,
      commandGenerator,
      commandTopic: commandTopicOutputs,
      eventLog: eventLog->Component.extractOutputs,
    })
  }

  let make = (~opts=?) =>
    make(~componentType=componentType->ComponentType.toString, ~name=Spec.name, ~construct, ~opts)
}
