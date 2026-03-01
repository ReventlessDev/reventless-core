module type T = {
  module Id: Id.T

  @schema
  type event
}

type outputs = {resources: array<Adapter.resource>}
type allOutputs = dict<outputs>
type publishJson = (string, Message.meta, JSON.t) => promise<unit>
type publishJsonStreamItem = {
  service: string,
  meta: Message.meta,
  json: JSON.t,
}
type publishJsonStream = Stream.t<publishJsonStreamItem, string, unit> => Effect.t<unit, string, unit>
