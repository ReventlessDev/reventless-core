let componentType = ComponentType.CommandTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}

let toUnwrappedOutputs = (outputs: outputs): Pulumi.Output.t<unwrappedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToUnwrappedOutput
  ->Pulumi.Output.apply(resources => {
    let unwrappedOutputs: unwrappedOutputs = {resources: resources}
    unwrappedOutputs
  })

type t

exception NotPublishedToChannel(Js.Promise.error)

type topicItem<'command> = {
  command: 'command,
  reference: string,
}

type publish<'id, 'command> = Message.command'<'id, 'command> => Js.Promise.t<unit>
type publishJsons = array<Message.commandJson> => Js.Promise.t<unit>

type jsonCommandsHandler = array<topicItem<Js.Json.t>> => promise<array<result<string, string>>>
type commandsHandler<'command> = array<topicItem<'command>> => Js.Promise.t<
  array<Belt.Result.t<string, string>>,
>

module type Spec = {
  module Id: ReventlessSpec.Id.T

  @decco
  type command
}

module type T = {
  module Spec: Spec
  type callbackEvent

  type publish = publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: publishJsons,
  }
  type component = Component.t<t, outputs, operations>

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let subscribe: (
    ~name: string,
    ~commandTopic: component,
    ~runtime: Runtime.environment,
    ~opts: Pulumi.ComponentResource.options,
  ) => unit

  let makeHandler: (
    ~commandTopic: component,
    ~commandsHandler: commandsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}
