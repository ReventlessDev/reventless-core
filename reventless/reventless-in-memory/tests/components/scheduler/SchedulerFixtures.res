// Fixtures for Scheduler component integration tests.
// Uses ScheduledPublisher_InMemory + Scheduler_Builder to verify schedule lifecycle.

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Isolated bus + scheduled publisher + scheduler maker
// ─────────────────────────────────────────────────────────────

module Bus = InMemory_Bus.Make()
module SP = ScheduledPublisher_InMemory.Make(Bus)
module SchedulerMaker = ReventlessCore.Scheduler_Builder.Make(SP)

// ─────────────────────────────────────────────────────────────
// Build the scheduler component (shared across tests)
// ─────────────────────────────────────────────────────────────

let scheduler = SchedulerMaker.make()

// ─────────────────────────────────────────────────────────────
// Helper: resolved Adapter.resolvedResource for a named bus topic
// ─────────────────────────────────────────────────────────────

let makeTopicResource = (name: string): Reventless.Adapter.resolvedResource => {
  name,
  id: name,
  urn: name,
  info: "",
  service: "InMemory",
}
