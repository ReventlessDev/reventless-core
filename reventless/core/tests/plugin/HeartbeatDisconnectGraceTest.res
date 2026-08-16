// Regression tests for the plugin-lifecycle heartbeat / disconnect margin.
//
// A plugin's liveness is scheduler-driven: every heartbeat re-arms a one-time
// disconnect schedule, and if heartbeats stop the schedule fires and marks the
// plugin Disconnected. Two independently-wired values must agree — the recurring
// heartbeat *schedule rate* and the *interval carried inside the Heartbeat command*
// (which drives CreateDisconnectSchedule). A deployed plugin once ran with schedule
// rate(60min) but a Heartbeat(10) command (grace ~12min), so it reconnected for
// ~12min after each hourly beat then sat Disconnected for the rest of the hour —
// it flapped. See docs/plans/done/plugin-heartbeat-disconnect-margin-hardening.md.
//
// These tests pin the two guarantees that the fix provides at this layer:
//   1. the disconnect grace scales with the interval (large cadences keep headroom);
//   2. the disconnect schedule the EP mapping arms is derived from the *same*
//      interval the Heartbeat/RedetectPlugin command carries — never a constant.
// (The schedule-rate ⇄ command-interval single-source is additionally enforced at
//  compile time now that Heartbeat_Builder's ~timeout is mandatory.)

open JestGlobals

module PluginExtensionPointSpec = ReventlessInfra.PluginExtensionPointSpec
open ReventlessInfra.ExtensionPointMapping

// The mapping functor only needs runtimeOps at directive-*execution* time; the
// pure mapIncomingCommand under test never touches it, so a stub Spec suffices
// (mirrors the Obj.magic stubbing already used in HeartbeatTest.res).
module TestMapping = PluginExtensionPoint_Plugin.Make({
  let runtimeOps = Obj.magic()
  let environment = "test"
  let updateApiSchema = None
  let manageSubscriptions = None
})

// Pull the disconnect-schedule grace (in minutes) out of the actions a mapping
// emits for an incoming command, if any.
let graceFromActions = actions =>
  actions->Array.findMap((action: commandAction<_, _>) =>
    switch action {
    | HandleDirective(_, PluginExtensionPointSpec.CreateDisconnectSchedule(_, timeout)) =>
      Some(timeout)
    | _ => None
    }
  )

let meta = Message.generateMeta(~service="test", ~user="test")

describe("disconnectGrace", () => {
  // The observed-bug fix: the margin must scale, so a 60-min cadence keeps real
  // headroom instead of the old fixed +2 (~3%).
  testSync("scales with the interval (5→7, 10→15, 60→90)", () => {
    expect(PluginExtensionPoint_Plugin.disconnectGrace(5))->toBe(7)
    expect(PluginExtensionPoint_Plugin.disconnectGrace(10))->toBe(15)
    expect(PluginExtensionPoint_Plugin.disconnectGrace(60))->toBe(90)
  })

  testSync("always leaves at least a full interval of headroom past one beat", () => {
    // Grace must exceed the interval (else a single beat's cadence trips a
    // disconnect) and keep the historical ≥ +2 min floor for small intervals.
    [1, 2, 5, 10, 30, 60, 120]->Array.forEach(interval => {
      let grace = PluginExtensionPoint_Plugin.disconnectGrace(interval)
      expect(grace > interval)->toBe(true)
      expect(grace >= interval + 2)->toBe(true)
    })
  })

  testSync("a 60-min cadence gets far more than the old fixed +2 grace", () => {
    // The exact regression: interval 60 previously armed a 62-min disconnect.
    expect(PluginExtensionPoint_Plugin.disconnectGrace(60) > 62)->toBe(true)
  })
})

describe("PluginExtensionPoint mapping arms the disconnect schedule from the beat interval", () => {
  testSync("Heartbeat(interval) → CreateDisconnectSchedule(_, disconnectGrace(interval))", () => {
    [5, 10, 60]->Array.forEach(interval => {
      let actions = TestMapping.PluginMapping.mapIncomingCommand(
        "Test@1",
        PluginExtensionPointSpec.Heartbeat(interval),
        meta,
      )
      expect(actions->graceFromActions)->toEqual(
        Some(PluginExtensionPoint_Plugin.disconnectGrace(interval)),
      )
    })
  })

  testSync("RedetectPlugin(interval) arms the same interval-derived grace as a heartbeat", () => {
    [5, 10, 60]->Array.forEach(interval => {
      let actions = TestMapping.PluginMapping.mapIncomingCommand(
        "Test@1",
        PluginExtensionPointSpec.RedetectPlugin(interval),
        meta,
      )
      expect(actions->graceFromActions)->toEqual(
        Some(PluginExtensionPoint_Plugin.disconnectGrace(interval)),
      )
    })
  })
})
