// Integration test fixtures for QueryDb builder (in-memory).

// ─────────────────────────────────────────────────────────────
// Test state spec
// ─────────────────────────────────────────────────────────────

module ItemQueryDbSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestItemQueryDb"

  @schema
  type state = {name: string, count: int}

  let config = Reventless.ReadModel.config()
  let subIdConfig = None
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build QueryDb using in-memory adapters
// ─────────────────────────────────────────────────────────────

module QDbStorage = QueryDbStorage_InMemory.Make(Bus)
module QDbResolvers = ReventlessCore.QueryDb_Adapter.NoResolvers(QDbStorage)
module QueryDbMaker = ReventlessCore.QueryDb_Builder.Make(
  ItemQueryDbSpec,
  QDbStorage,
  QDbResolvers,
)

let queryDb = QueryDbMaker.make(~api=(), ~apiRole=())
