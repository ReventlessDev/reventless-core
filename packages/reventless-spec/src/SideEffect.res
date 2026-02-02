module type Source = {
  let name: string
  module Id: Id.T
  @schema
  type event
}

module type T = {
  module Source: Source
  let execute: (Source.Id.t, Message.meta, Source.event, QueryEngine.operations) => promise<unit>
}
