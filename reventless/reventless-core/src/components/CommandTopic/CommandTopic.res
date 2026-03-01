let componentType = ComponentType.CommandTopic

type outputs = Reventless.CommandTopic.outputs
type allOutputs = Reventless.CommandTopic.allOutputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception NotPublishedToChannel(exn)

include CommandTopic_Helpers

type publish<'id, 'command> = Message.command'<'id, 'command> => promise<unit>
type publishJsons = Reventless.CommandTopic.publishJsons
type publishJsonsStream = Reventless.CommandTopic.publishJsonsStream

type commandsHandler<'command> = array<topicItem<'command>> => promise<
  array<result<string, string>>,
>

module type T = {
  module Spec: Reventless.CommandTopic.T
  type callbackEvent

  type publish = publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: publishJsons,
    publishJsonsStream: Reventless.CommandTopic.publishJsonsStream,
  }
  type component = component<operations>

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let connect: (
    ~runtime: Runtime.environment<'runtimeParts>,
    ~resources: array<Reventless.Adapter.resource>,
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

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.CommandTopic.resolvedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToResolvedOutput
  ->Pulumi.Output.apply(resources => {
    let resolved: ReventlessInterop.CommandTopic.resolvedOutputs = {
      resources: resources->Array.map(
        (r: Adapter.resolvedResource): ReventlessInterop.Resource.t => {
          name: r.name,
          id: r.id,
          urn: r.urn,
          info: r.info,
          service: r.service,
        },
      ),
    }
    resolved
  })

let filter = (allCommandTopics: allOutputs, names) =>
  names
  ->Set.values
  ->Iterator.toArray
  ->Array.filterMap(name =>
    allCommandTopics->Dict.get(name)->Option.map(commandTopic => (name, commandTopic))
  )
  ->Dict.fromArray
