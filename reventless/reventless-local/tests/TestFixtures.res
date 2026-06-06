// Shared test infrastructure for all component integration tests.

// ─────────────────────────────────────────────────────────────
// Test metadata
// ─────────────────────────────────────────────────────────────

let testMeta: Reventless.Message.meta = {
  service: "test",
  time: "2024-01-01T00:00:00.000Z",
  ip: "127.0.0.1",
  user: "testuser",
  msgId: "msg-001",
  correlationId: "corr-001",
}

// For tests where meta.service must match a specific source name for routing.
let makeTestMeta = (~service): Reventless.Message.meta => {...testMeta, service}

// ─────────────────────────────────────────────────────────────
// Mock infrastructure
// ─────────────────────────────────────────────────────────────

let mockQueryEngine: Reventless.QueryEngine.operations = {
  scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
  query: async (
    ~readModelName as _,
    ~key as _=?,
    ~id as _,
    ~subIdConfig as _=?,
    ~filterConfigs as _=?,
    ~ascending as _=?,
    ~limit as _=?,
  ) => [],
}

let mockScheduler: ReventlessInfra.Scheduler.operations = {
  createSchedule: async (_, _) => (),
  deleteSchedule: async (_, _) => (),
}

let mockResourceNaming: ReventlessInfra.ResourceNaming.operations = {
  validateName: n => n,
  urnName: n => n,
}

// ─────────────────────────────────────────────────────────────
// Jest fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"
