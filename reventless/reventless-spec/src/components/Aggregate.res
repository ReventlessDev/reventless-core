module type Spec = {
  module Id: Id.T

  let name: string

  @schema
  type command

  @schema
  type event

  @schema
  type error
}

type rec addEventMapper = (EventTopic.allOutputs, QueryEngine.operations) => outputs
and outputs = {
  name: string,
  commandGenerator: Pulumi.Output.t<CommandGenerator.outputs>,
  commandTopic: Pulumi.Output.t<CommandTopic.outputs>,
  eventLog: EventLog.outputs,
  eventMapper?: Pulumi.Output.t<EventMapper.outputs>,
  addEventMapper: addEventMapper,
}
type allOutputs = dict<outputs>
type operations = {publishJsons: CommandTopic.publishJsons}

module type T = {
  module Spec: Spec
  type api
  type component
  let make: (~api: api, ~opts: Pulumi.ComponentResource.options=?) => component
  let outputs: component => outputs
  let operations: component => Pulumi.Output.t<operations>
  let finish: unit => unit
}
