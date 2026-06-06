// Fixtures for Scheduler component integration tests.
// Uses LocalScheduledPublisher + Scheduler_Builder to verify schedule lifecycle.

open TestFixtures
open ReventlessGwt.AsyncTest

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Isolated bus + scheduled publisher + scheduler maker
// ─────────────────────────────────────────────────────────────

module Bus = LocalBus.Make()
module SP = LocalScheduledPublisher.Make(Bus)
module SchedulerMaker = ReventlessCore.Scheduler_Builder.Make(SP)

// ─────────────────────────────────────────────────────────────
// Build the scheduler component (shared across tests)
// ─────────────────────────────────────────────────────────────

let scheduler = SchedulerMaker.make()

// ─────────────────────────────────────────────────────────────
// Helper: resolved Adapter.resolvedResource for a named bus topic
// ─────────────────────────────────────────────────────────────

let makeTopicResource = (name: string): ReventlessInfra.Adapter.resolvedResource => {
  name,
  id: name,
  urn: name,
  resourceInfo: NoInfo,
  service: "memory:InMemory",
  role: "",
  region: "",
  resourceType: "",
  configuration: Dict.make(),
  tags: Dict.make(),
}

let _ = beforeAll(() => {
  jest->useFakeTimers
})

let _ = afterAll(() => {
  SP.reset()
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Resolve scheduler operations once for all tests
// ─────────────────────────────────────────────────────────────

let schedulerOps: ref<option<ReventlessInfra.Scheduler.operations>> = ref(None)

let _ = beforeAllAsync(async () => {
  let ops = await scheduler->ReventlessCore.Component.operations->TestRunner.resolve
  schedulerOps := Some(ops)
})
