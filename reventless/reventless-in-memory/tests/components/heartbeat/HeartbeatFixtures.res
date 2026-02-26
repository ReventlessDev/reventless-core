// Fixtures for Heartbeat component integration tests.
// Uses HeartbeatRunner_InMemory and fake timers to verify the handler fires on schedule.

// Activate Pulumi mock mode (must be called before any Component.make)
let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Build the Heartbeat component maker
// ─────────────────────────────────────────────────────────────

module HeartbeatMaker = ReventlessCore.Heartbeat_Builder.Make(HeartbeatRunner_InMemory)
