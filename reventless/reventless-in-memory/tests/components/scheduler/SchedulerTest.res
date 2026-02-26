// Integration tests for Scheduler_Builder (in-memory).
// Verifies that createSchedule fires events and deleteSchedule prevents firing.
// Adapter-level timer tests are in adapter/ScheduledPublisherTest.res.

open AsyncTest
open AsyncTest.Expect
open SchedulerFixtures

// ─────────────────────────────────────────────────────────────
// Fake timer bindings
// ─────────────────────────────────────────────────────────────

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, int) => unit = "advanceTimersByTime"

let _ = beforeAll(() => {
  jest->useFakeTimers
})

let _ = afterAll(() => {
  SP.reset()
  jest->useRealTimers
})

// ─────────────────────────────────────────────────────────────
// Resolve scheduler operations once for all tests.
// In mock mode, scheduler.operations is Output.t<Scheduler.operations>;
// await resolves it synchronously.
// ─────────────────────────────────────────────────────────────

let schedulerOps: ref<option<Reventless.Scheduler.operations>> = ref(None)

let _ = beforeAllAsync(async () => {
  let ops = await scheduler->ReventlessCore.Component.operations->TestRunner.resolve
  schedulerOps := Some(ops)
})

describe("Scheduler_Builder.Make:", () => {
  let _ = afterEach(() => SP.reset())

  describe("createSchedule:", () => {
    testPromise("recurring schedule fires event on each interval advance", async () => {
      let ops = schedulerOps.contents->Option.getUnsafe
      let count = ref(0)
      Bus.subscribeToEvents("sched-recurring", async (_, _, _) => {
        count := count.contents + 1
      })
      // createSchedule async body has no await — setInterval registered synchronously
      let _ = ops.createSchedule(
        [makeTopicResource("sched-recurring")],
        {name: "test-recurring", rate: Reventless.Schedule.Minutes(1), payload: "{}"},
      )
      jest->advanceTimersByTime(60 * 1000)
      expect(count.contents)->toBe(1)
      jest->advanceTimersByTime(60 * 1000)
      expect(count.contents)->toBe(2)
    })

    testPromise("single-shot schedule fires once then stops", async () => {
      let ops = schedulerOps.contents->Option.getUnsafe
      let count = ref(0)
      Bus.subscribeToEvents("sched-single", async (_, _, _) => {
        count := count.contents + 1
      })
      let _ = ops.createSchedule(
        [makeTopicResource("sched-single")],
        {
          name: "test-single",
          rate: Reventless.Schedule.Single(2024, 1, 1, 0, 0),
          payload: "{}",
        },
      )
      jest->advanceTimersByTime(0)
      expect(count.contents)->toBe(1)
      jest->advanceTimersByTime(60 * 1000)
      expect(count.contents)->toBe(1) // No further firing
    })
  })

  describe("deleteSchedule:", () => {
    testPromise("deleted schedule does not fire after deletion", async () => {
      let ops = schedulerOps.contents->Option.getUnsafe
      let count = ref(0)
      Bus.subscribeToEvents("sched-delete", async (_, _, _) => {
        count := count.contents + 1
      })
      let _ = ops.createSchedule(
        [makeTopicResource("sched-delete")],
        {name: "test-delete", rate: Reventless.Schedule.Minutes(2), payload: "{}"},
      )
      let _ = ops.deleteSchedule([], "test-delete")
      jest->advanceTimersByTime(2 * 60 * 1000)
      expect(count.contents)->toBe(0)
    })
  })
})
