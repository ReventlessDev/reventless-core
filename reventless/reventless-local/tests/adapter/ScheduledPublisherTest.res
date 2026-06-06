// Unit tests for LocalScheduledPublisher.
// Uses fake timers to verify createSchedule, deleteSchedule, and reset.

open ReventlessGwt.AsyncTest
open ReventlessGwt.AsyncTest.Expect

// ─────────────────────────────────────────────────────────────
// Fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external runAllTimers: jestObj => unit = "runAllTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"

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

let makeTopicResource = (topicName: string): ReventlessInfra.Adapter.resolvedResource => {
  name: topicName,
  id: topicName,
  urn: topicName,
  resourceInfo: NoInfo,
  service: "memory:InMemory",
  role: "",
  region: "",
  resourceType: "",
  configuration: Dict.make(),
  tags: Dict.make(),
}

describe("LocalScheduledPublisher", () => {
  describe("createSchedule", () => {
    testPromise("single-shot schedule fires event after runAllTimers", async () => {
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("sched-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "one-shot",
        rate: Reventless.Schedule.Single(2024, 1, 1, 0, 0),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("sched-topic")], schedule)
      jest->runAllTimers
      // Two microtask ticks: publishEvent uses Effect.all(concurrency=unbounded) which forks
      // child fibers via startFork — one tick for the child fiber to offer to the Queue,
      // a second tick for the drain fiber to run the callback.
      let _ = await Promise.resolve(())
      let _ = await Promise.resolve(())
      expect(count.contents)->toBe(1)
      SP.reset()
    })

    testPromise("recurring schedule fires on each interval advance", async () => {
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("repeat-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler2", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "every-minute",
        rate: Reventless.Schedule.Minutes(1),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("repeat-topic")], schedule)
      jest->advanceTimersByTime(60 * 1000)
      let _ = await Promise.resolve(())
      let _ = await Promise.resolve(())
      jest->advanceTimersByTime(60 * 1000)
      let _ = await Promise.resolve(())
      let _ = await Promise.resolve(())
      expect(count.contents)->toBe(2)
      SP.reset()
    })
  })

  describe("deleteSchedule", () => {
    testPromise("clears a named schedule; advancing timers does not fire it", async () => {
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("del-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler3", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "to-delete",
        rate: Reventless.Schedule.Minutes(1),
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
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("reset-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="scheduler4", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "reset-sched",
        rate: Reventless.Schedule.Minutes(5),
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
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("rate-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="rate-scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "rate-sched",
        rate: Reventless.Schedule.Minutes(3),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("rate-topic")], schedule)
      // Advance by slightly less than 3 minutes — should not fire
      jest->advanceTimersByTime(3 * 60 * 1000 - 1)
      expect(count.contents)->toBe(0)
      // Advance the remaining millisecond — now fires; two ticks for Effect.all drain
      jest->advanceTimersByTime(1)
      let _ = await Promise.resolve(())
      let _ = await Promise.resolve(())
      expect(count.contents)->toBe(1)
      SP.reset()
    })

    testPromise("Hours(n) fires after n hours", async () => {
      module TestBus = LocalBus.Make()
      module SP = LocalScheduledPublisher.Make(TestBus)
      let count: ref<int> = ref(0)
      TestBus.subscribeToEvents("hours-topic", async (_, _, _) => {
        count := count.contents + 1
      })
      let pub = SP.make(~name="hours-scheduler", ~opts={})
      let ops = await pub.operations->TestRunner.resolve
      let schedule: Reventless.Schedule.schedule = {
        name: "hours-sched",
        rate: Reventless.Schedule.Hours(2),
        payload: "{}",
      }
      await ops.createSchedule([makeTopicResource("hours-topic")], schedule)
      jest->advanceTimersByTime(2 * 60 * 60 * 1000)
      let _ = await Promise.resolve(())
      let _ = await Promise.resolve(())
      expect(count.contents)->toBe(1)
      SP.reset()
    })
  })
})
