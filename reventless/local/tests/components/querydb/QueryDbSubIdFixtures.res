// Fixtures for QueryDb sub-ID tests.
// Uses a spec with composite sub-key (_subId = region + "/" + date).

// ─────────────────────────────────────────────────────────────
// Test state spec with subIdConfig
// ─────────────────────────────────────────────────────────────

module MetricSpec = {
  module Id = Reventless.Id.StringPure
  let name = "TestMetricQueryDb"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type state = {userId: string, region: string, date: string, value: float}

  let config = Reventless.ReadModel.config()

  let subIdConfig: option<Reventless.ReadModel.subIdConfig<state>> = Some({
    subIdField: "_subId",
    getSubId: (state: state) => state.region ++ "/" ++ state.date,
  })
}

// ─────────────────────────────────────────────────────────────
// Bus and Pulumi setup
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build QueryDb using in-memory adapters
// ─────────────────────────────────────────────────────────────

module QDbStorage = LocalQueryDbStorage.Make(Bus)
module QDbResolvers = ReventlessCore.QueryDb_Adapter.NoResolvers(QDbStorage)
module MetricQueryDbMaker = ReventlessCore.QueryDb_Builder.Make(
  MetricSpec,
  QDbStorage,
  QDbResolvers,
)

let metricQueryDb = MetricQueryDbMaker.make(~api=(), ~apiRole=())
