module type T = {
  module Id: Id.T

  @schema
  type command
}

type outputs = {resources: array<Adapter.resource>}
type allOutputs = dict<outputs>
type publishJsons = array<Message.commandJson> => promise<unit>
type publishJsonsStream = Stream.t<Message.commandJson, string, unit> => Effect.t<unit, string, unit>

type topicItem<'command> = {
  command: 'command,
  reference: string,
}
