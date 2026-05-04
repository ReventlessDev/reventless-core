// Fixtures for Task integration tests.
// Tests Task_Builder.Make wiring with in-memory adapters.

S.enableJson()

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Isolated bus
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()

// ─────────────────────────────────────────────────────────────
// In-memory Task builder (parametrised by Bus)
// ─────────────────────────────────────────────────────────────

module TaskBuilderWithBus = Task_Builder.Make(Bus)

// ─────────────────────────────────────────────────────────────
// Task spec — no buckets (smoke test for minimal setup)
// ─────────────────────────────────────────────────────────────

module NoBucketsSpec = {
  let name = "NoBucketsTask"
  let moduleUrl: string = %raw(`import.meta.url`)

  let setup = (
    _queryEngine: Reventless.QueryEngine.operations,
    _queryBucketName: ReventlessInfra.Task.queryBucketName,
    _opts: Pulumi.ComponentResource.options,
  ): Reventless.Task.config => {}
}

// ─────────────────────────────────────────────────────────────
// Task spec — one named bucket with a callback
// ─────────────────────────────────────────────────────────────

let capturedEvents: ref<array<(string, string)>> = ref([])

module OneBucketSpec = {
  let name = "OneBucketTask"
  let moduleUrl: string = %raw(`import.meta.url`)

  let setup = (
    _queryEngine: Reventless.QueryEngine.operations,
    _queryBucketName: ReventlessInfra.Task.queryBucketName,
    _opts: Pulumi.ComponentResource.options,
  ): Reventless.Task.config => {
    buckets: [
      {
        bucketName: "Reports",
        bucketMode: Reventless.Task.Read,
        callback: async (~eventName, ~key) => {
          capturedEvents :=
            capturedEvents.contents->Array.concat([(eventName, key)])
          []
        },
      },
    ],
  }
}

// ─────────────────────────────────────────────────────────────
// Mock infrastructure (shared across tests)
// ─────────────────────────────────────────────────────────────

let mockPublishToAggregates: dict<ReventlessInfra.CommandTopic.publishJsons> = Dict.make()

let mockQueryBucketName: ReventlessInfra.Task.queryBucketName = (~taskName as _, ~bucketName as _=?) =>
  "in-memory-bucket"

// ─────────────────────────────────────────────────────────────
// Pre-built task makers
// ─────────────────────────────────────────────────────────────

module NoBucketsMaker = TaskBuilderWithBus.Make(NoBucketsSpec)
module OneBucketMaker = TaskBuilderWithBus.Make(OneBucketSpec)

// ─────────────────────────────────────────────────────────────
// Helper to reset captured state between tests
// ─────────────────────────────────────────────────────────────

let resetCaptures = () => {
  capturedEvents := []
}
