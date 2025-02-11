let componentType: ComponentType.t

type outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventLog: EventLog.outputs,
  eventMapper?: Pulumi.Output.t<EventMapper.outputs>,
}
type allOutputs = Js.Dict.t<outputs>

let allEventTopics: Js.Dict.t<outputs> => Js.Dict.t<EventTopic.outputs>
let filterEventTopics: (Js.Dict.t<outputs>, Belt.Set.String.t) => Js.Dict.t<EventTopic.outputs>

type name = string

type t
type component = Component.t<t, outputs, unit>

type addEventMapper = (EventTopic.allOutputs, ReventlessSpec.QueryEngine.operations) => outputs
module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
  let publishJsons: component => Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>
  let addEventMapper: component => addEventMapper
}
module Make: (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: {
    type state
    let resolverConfig: Behaviour.resolverConfig<Spec.command>
    let init: Behaviour.init<state, Spec.event>
    let apply: Behaviour.apply<state, Spec.event>
    let create: Behaviour.create<Spec.command, Spec.event, Spec.error>
    let execute: Behaviour.execute<state, Spec.command, Spec.event, Spec.error>
  },
  EventMappings: {
    module type Mapping = {
      module Source: ReventlessSpec.EventMapping.Source
      let map: (
        Source.Id.t,
        Source.event,
        ReventlessSpec.QueryEngine.operations,
      ) => array<ReventlessSpec.EventMapping.action<Spec.Id.t, Spec.command>>
    }
    let mappings: array<module(Mapping)>
    let counter: option<module(Counter.T)>
  },
  CommandGeneratorResolvers: {
    let make: CommandGenerator.Adapter.resolversMaker<Config.api>
  },
  CommandTopicConnector: CommandTopic.Adapter.Connector,
  EventLogStorage: EventLog.Adapter.Storage,
  EventTopicPublisher: EventTopic.Adapter.Publisher,
  EventCollectorConnector: EventCollector.Adapter.Connector,
) =>
{
  module Spec: {
    module Id: {
      type t = Spec.Id.t
      let t_encode: t => Js.Json.t
      let t_decode: Js.Json.t => Belt.Result.t<t, Decco.decodeError>
      type input = Spec.Id.input
      let make: input => t
      let makeFromString: string => t
      let toString: t => string
      let cmp: (t, t) => Ordering.t
    }
    let name: string
    type command = Spec.command
    let command_encode: command => Js.Json.t
    let command_decode: Js.Json.t => Belt.Result.t<command, Decco.decodeError>
    type event = Spec.event
    let event_encode: event => Js.Json.t
    let event_decode: Js.Json.t => Belt.Result.t<event, Decco.decodeError>
    type error = Spec.error
    let error_encode: error => Js.Json.t
    let error_decode: Js.Json.t => Belt.Result.t<error, Decco.decodeError>
  }
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
  let publishJsons: component => Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>
  let addEventMapper: component => addEventMapper
}
