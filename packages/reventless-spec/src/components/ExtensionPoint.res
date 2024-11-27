type outputs = {
  name: string,
  aggregateNames: array<string>,
  outgoingEventHandler: (Js.Json.t, Plugin.pluginDefinition) => Js.Promise.t<unit>,
  commandTopic: CommandTopic.outputs,
  eventTopic: EventTopic.outputs,
}

module type Spec = {
  module Id = Id.String

  let name: string

  @decco
  type command
  @decco
  type event
  @decco
  type callCommand
}

module type T = {
  type t
  let make: (
    ~publishToAggregates: Js.Dict.t<CommandTopic.publishJsons>,
    ~scheduler: Scheduler.t,
    ~queryEngine: ReventlessSpec.QueryEngine.t,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => //TODO remove after rescript 11 update
  ReventlessSpec.Component.t<t, outputs>
}
