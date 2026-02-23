module type T = {
  module Id: Id.T

  let name: string

  @schema
  type event
}

type outputs = {resources: array<Adapter.resource>, eventTopic: EventTopic.outputs}
