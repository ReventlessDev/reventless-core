/** see AggregateSpec.T */
module type Source = {
  let name: string
  module Id: Id.T
  @decco
  type event
}

module type T = {
  module Source: Source
  let execute: (Source.Id.t, Message.meta, Source.event, QueryEngine.t) => Js.Promise.t<unit>
}
