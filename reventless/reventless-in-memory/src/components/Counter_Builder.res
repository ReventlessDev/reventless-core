// In-memory Counter builder.

module Make = (Bus: InMemory_Bus.T) => {
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  module Api = {
    let api = () => ()
    let apiRole = () => ()
  }
  include ReventlessCore.Counter_Builder.Make(
    QueryDbStorage,
    Api,
    CounterHandler_InMemory,
  )
}
