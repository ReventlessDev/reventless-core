// Unit tests for ScheduledPublisher_InMemory.
// Uses fake timers to verify createSchedule, deleteSchedule, and reset.

open AsyncTest
open AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external runAllTimers: jestObj => unit = "runAllTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"

// In Jest ESM mode, jest global is only available inside callbacks (not at module top level).
let _ = beforeAll(() => {
  jest->useFakeTimers
})

// ─────────────────────────────────────────────────────────────
// Pulumi mock (needed for Pulumi.Output.make in ScheduledPublisher)
// ─────────────────────────────────────────────────────────────

let _ = TestRunner.setup()

// ─────────────────────────────────────────────────────────────
// Restore real timers after all tests in this file
// ─────────────────────────────────────────────────────────────

let _ = afterAll(() => {
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Helper: create a topic resource with a known name
// ─────────────────────────────────────────────────────────────

let makeTopicResource = (topicName: string): ReventlessSpec.Adapter.unwrappedResource => {
  name: topicName,
  id: topicName,
  urn: topicName,
  info: "",
  service: "InMemory",
}

describe("ScheduledPublisher_InMemory", () => {
  describe("createSchedule", () => {
    testPromise("single-shot schedule fires event after runAllTimers", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("sched-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "one-shot",
        rate: ReventlessSpec.Schedule.Single(2024, 1, 1, 0, 0),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("sched-topic")], schedule)
      jest->runAllTimers
      // Bus.publishEvent runs subscriber bodies synchronously before first await
      expect(count.contents)->toBe(1)
      SP.reset()
    })

    testPromise("recurring schedule fires on each interval advance", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("repeat-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler2", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "every-minute",
        rate: ReventlessSpec.Schedule.Minutes(1),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("repeat-topic")], schedule)
      jest->advanceTimersByTime(60 * 1000)
      jest->advanceTimersByTime(60 * 1000)
      expect(count.contents)->toBe(2)
      SP.reset()
    })
  })

  describe("deleteSchedule", () => {
    testPromise("clears a named schedule; advancing timers does not fire it", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("del-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler3", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "to-delete",
        rate: ReventlessSpec.Schedule.Minutes(1),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("del-topic")], schedule)
      await ops.deleteSchedule([], "to-delete")
      jest->advanceTimersByTime(60 * 1000)
      expect(count.contents)->toBe(0)
      SP.reset()
    })
  })

  describe("reset", () => {
    testPromise("clears all active timers; subsequent advance does not fire", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("reset-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler4", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "reset-sched",
        rate: ReventlessSpec.Schedule.Minutes(5),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("reset-topic")], schedule)
      SP.reset()
      jest->advanceTimersByTime(5 * 60 * 1000)
      expect(count.contents)->toBe(0)
    })
  })

  describe("rateToMs", () => {
    testPromise("Minutes(n) fires after n minutes", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("rate-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="rate-scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "rate-sched",
        rate: ReventlessSpec.Schedule.Minutes(3),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("rate-topic")], schedule)
      // Advance by slightly less than 3 minutes — should not fire
      jest->advanceTimersByTime(3 * 60 * 1000 - 1)
      expect(count.contents)->toBe(0)
      // Advance the remaining millisecond — now fires
      jest->advanceTimersByTime(1)
      expect(count.contents)->toBe(1)
      SP.reset()
    })

    testPromise("Hours(n) fires after n hours", async () => {
      module TestBus = InMemory_Bus.Make()
      module SP = ScheduledPublisher_InMemory.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("hours-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="hours-scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: ReventlessSpec.Schedule.schedule = {
        name: "hours-sched",
        rate: ReventlessSpec.Schedule.Hours(2),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("hours-topic")], schedule)
      jest->advanceTimersByTime(2 * 60 * 60 * 1000)
      expect(count.contents)->toBe(1)
      SP.reset()
    })
  })
})
