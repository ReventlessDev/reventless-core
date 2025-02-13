let componentType = ComponentType.CommandTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}

type t

exception NotPublishedToConnector(Js.Promise.error)

type publish<'id, 'command> = Message.command'<'id, 'command> => Js.Promise.t<unit>
type publishJsons = array<Message.commandJson> => Js.Promise.t<unit>

type topicItem<'command> = {
  command: 'command,
  reference: string,
}

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

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  type publish = publish<Spec.Id.t, Spec.command>
  type operations = {publish: publish, publishJsons: publishJsons}
  type component = Component.t<t, outputs, operations>

  let make: (
    ~name: string,
    ~commandsHandler: commandsHandler,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
