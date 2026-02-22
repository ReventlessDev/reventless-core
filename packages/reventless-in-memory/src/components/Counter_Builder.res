// In-memory Counter builder.

module Make = (Bus: InMemory_Bus.T) =>
  Reventless.Counter_Builder.Make(
    QueryDbStorage_InMemory,
    {
      let api = ()
      let apiRole = ()
    },
    CounterHandler_InMemory,
  )
