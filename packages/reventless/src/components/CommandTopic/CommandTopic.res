let componentType = ComponentType.CommandTopic

type unwrappedOutputs = {resources: array<Adapter.unwrappedResource>}
type outputs = {resources: array<ReventlessSpec.Adapter.resource>}
type allOutputs = dict<outputs>

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception NotPublishedToChannel(exn)

include CommandTopic_Helpers

type publish<'id, 'command> = Message.command'<'id, 'command> => promise<unit>
type publishJsons = array<Message.commandJson> => promise<unit>

type commandsHandler<'command> = array<topicItem<'command>> => promise<
  array<result<string, string>>,
>

module type T = {
  module Spec: ReventlessSpec.CommandTopic_Spec.T
  type callbackEvent

  type publish = publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: publishJsons,
  }
  type component = component<operations>

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let connect: (
    ~runtime: Runtime.environment<'runtimeParts>,
    ~resources: array<ReventlessSpec.Adapter.resource>,
    component,
  ) => unit

  let registerHandler: (
    ~commandTopic: component,
    ~schema: S.t<unknown>,
    ~handler: jsonCommandsHandler,
    ~typeNames: array<string>,
  ) => unit

  let makeHandler: (
    ~commandTopic: component,
    ~commandsHandler: commandsHandler,
  ) => Pulumi.Output.t<Runtime.eventHandler<callbackEvent, 'context, unit>>

  // Returns the filtering handler output for runtime connection
  // Registers the handler with the channel's event routing
  let makeFilteringHandler: component => Pulumi.Output.t<
    Runtime.eventHandler<callbackEvent, 'context, unit>,
  >

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}

let toUnwrappedOutputs = (outputs: outputs): Pulumi.Output.t<unwrappedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToUnwrappedOutput
  ->Pulumi.Output.apply(resources => {
    let unwrappedOutputs: unwrappedOutputs = {resources: resources}
    unwrappedOutputs
  })

let filter = (allCommandTopics: allOutputs, names) =>
  names
  ->Set.values
  ->Iterator.toArray
  ->Array.filterMap(name =>
    allCommandTopics->Dict.get(name)->Option.map(commandTopic => (name, commandTopic))
  )
  ->Dict.fromArray
