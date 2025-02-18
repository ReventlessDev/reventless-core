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

type publish<'id, 'command> = Message.command'<'id, 'command> => Js.Promise.t<unit>
type publishJsons = array<Message.commandJson> => Js.Promise.t<unit>

type topicItem<'command> = {
  command: 'command,
  reference: string,
}

type commandsHandler<'command> = array<topicItem<'command>> => Js.Promise.t<
  array<Belt.Result.t<string, string>>,
>

type channel = {
  resources: array<ReventlessSpec.Adapter.resource>,
  publishJsons: Pulumi.Output.t<publishJsons>,
}

module type Spec = {
  module Id: ReventlessSpec.Id.T

  @decco
  type command
}

module type T = {
  module Spec: Spec

  type publish = publish<Spec.Id.t, Spec.command>
  type operations = {publish: publish, publishJsons: publishJsons}
  type component = Component.t<t, outputs, operations>

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let makeChannel: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => channel

  let make: (
    ~name: string,
    ~channel: channel,
    ~commandsHandler: commandsHandler,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
