module type T = {
  module Id: Id.T

  @schema
  type event
}

type outputs = {resources: array<Adapter.resource>}
type allOutputs = dict<outputs>
type publishJson = (string, Message.meta, JSON.t) => promise<unit>
