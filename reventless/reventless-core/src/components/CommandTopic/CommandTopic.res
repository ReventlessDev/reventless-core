let componentType = ComponentType.CommandTopic

type outputs = ReventlessInfra.CommandTopic.outputs
type allOutputs = ReventlessInfra.CommandTopic.allOutputs

type t
type component<'operations> = Component.t<t, outputs, 'operations>

exception NotPublishedToChannel(exn)

include CommandTopic_Helpers

type publish<'id, 'command> = Message.command'<'id, 'command> => promise<unit>
type publishJsons = ReventlessInfra.CommandTopic.publishJsons
type publishJsonsStream = ReventlessInfra.CommandTopic.publishJsonsStream

type commandsHandler<'command> = ReventlessInfra.CommandTopic.commandsHandler<'command>

type commandOutcome =
  | Accepted({msgId: string, entityId?: string, eventCount: int})
  | Rejected({msgId: string, errorCode: string, errorDetail: option<string>})
  | Pending({msgId: string})

type publishJsonsAndWait = array<Message.commandJson> => promise<array<commandOutcome>>

module type T = {
  module Spec: ReventlessInfra.CommandTopic.T
  type callbackEvent

  type publish = publish<Spec.Id.t, Spec.command>

  type operations = {
    publish: publish,
    publishJsons: publishJsons,
    publishJsonsStream: ReventlessInfra.CommandTopic.publishJsonsStream,
    publishJsonsAndWait: option<publishJsonsAndWait>,
  }
  type component = component<operations>

  type commandsHandler = commandsHandler<Message.command'<Spec.Id.t, Spec.command>>

  let connect: (
    ~runtime: Runtime.environment<'runtimeParts>,
    ~resources: array<ReventlessInfra.Adapter.resource>,
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
  ) => Pulumi.Output.t<Runtime.effectHandler<callbackEvent, 'context, unit, string>>

  // Returns the filtering handler output for runtime connection
  // Registers the handler with the channel's event routing
  let makeFilteringHandler: component => Pulumi.Output.t<
    Runtime.effectHandler<callbackEvent, 'context, unit, string>,
  >

  let make: (~name: string, ~opts: Pulumi.ComponentResource.options=?) => component
}

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.CommandTopic.resolvedOutputs> =>
  outputs.resources
  ->Adapter.resourcesToInterop
  ->Pulumi.Output.apply(resources => {
    let resolved: ReventlessInterop.CommandTopic.resolvedOutputs = {resources: resources}
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
