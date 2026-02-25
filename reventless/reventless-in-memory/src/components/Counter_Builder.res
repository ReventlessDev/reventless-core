// In-memory Counter builder.

module Make = (Bus: InMemory_Bus.T) => {
  module QueryDbStorage = QueryDbStorage_InMemory.Make(Bus)
  include Reventless.Counter_Builder.Make(
    QueryDbStorage,
    {
      let api = ()
      let apiRole = ()
    },
    CounterHandler_InMemory,
  )
}
