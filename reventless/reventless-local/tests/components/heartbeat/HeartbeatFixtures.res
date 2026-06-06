// Fixtures for Heartbeat component integration tests.
// Uses LocalHeartbeatRunner and fake timers to verify the handler fires on schedule.

open TestFixtures
open ReventlessGwt.AsyncTest

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build the Heartbeat component maker
// ─────────────────────────────────────────────────────────────

module HeartbeatMaker = ReventlessCore.Heartbeat_Builder.Make(LocalHeartbeatRunner)

let _ = beforeAll(() => {
  jest->useFakeTimers
})

let _ = afterAll(() => {
  LocalHeartbeatRunner.reset()
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Shared state — reset in beforeEach inside describe
// ─────────────────────────────────────────────────────────────

let capturedCount: ref<int> = ref(0)

let mockPublish: ReventlessInfra.CommandTopic.publishJsons = async cmds => {
  capturedCount := capturedCount.contents + cmds->Array.length
}

// resolvedHandler populated in beforeAllAsync before tests run.
// makeHandler returns eventHandler<unit, 'ctx, unit> = (unit, ctx) => promise<unit>.
// The runtime handlerRef expects (JSON.t, unit) => promise<unit> — same in JS, safe to cast.
let resolvedHandler: ref<option<(unit, unit) => promise<unit>>> = ref(None)

let _ = beforeAllAsync(async () => {
  let h =
    await HeartbeatMaker.makeHandler(
      ~id="hb-id-1",
      ~timeout=1,
      ~publishToPluginExtensionPoint=mockPublish,
    )->TestRunner.resolve
  resolvedHandler := Some(h)
})
