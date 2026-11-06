// Integration tests for Scheduler_Builder (in-memory).
// Verifies that createSchedule fires events and deleteSchedule prevents firing.
// Adapter-level timer tests are in adapter/ScheduledPublisherTest.res.

open TestFixtures
open JestGlobals
open SchedulerFixtures

describe("Scheduler_Builder.Make:", () => {
  let _ = afterEach(() => SP.reset())

  describe("createSchedule:", () => {
    testPromise(
      "recurring schedule fires event on each interval advance",
      async () => {
        let ops = schedulerOps.contents->Option.getUnsafe
        let count = ref(0)
        Bus.subscribeToEvents(
          "sched-recurring",
          async (_, _, _) => {
            count := count.contents + 1
          },
        )
        // createSchedule async body has no await — the timer is set synchronously
        let _ = ops.createSchedule(
          [makeTopicResource("sched-recurring")],
          {name: "test-recurring", time: Every(Minutes(1)), payload: "{}"},
        )
        await jest->advanceTimersByTimeAsync(60 * 1000)
        expect(count.contents)->toBe(1)
        await jest->advanceTimersByTimeAsync(60 * 1000)
        expect(count.contents)->toBe(2)
      },
    )

    testPromise(
      "single-shot schedule fires once then stops",
      async () => {
        let ops = schedulerOps.contents->Option.getUnsafe
        let count = ref(0)
        Bus.subscribeToEvents(
          "sched-single",
          async (_, _, _) => {
            count := count.contents + 1
          },
        )
        let _ = ops.createSchedule(
          [makeTopicResource("sched-single")],
          {
            name: "test-single",
            time: Once({moment: After(Minutes(1))}),
            payload: "{}",
          },
        )
        await jest->advanceTimersByTimeAsync(60 * 1000)
        expect(count.contents)->toBe(1)
        await jest->advanceTimersByTimeAsync(60 * 1000)
        expect(count.contents)->toBe(1) // No further firing
      },
    )
  })

  describe("deleteSchedule:", () => {
    testPromise(
      "deleted schedule does not fire after deletion",
      async () => {
        let ops = schedulerOps.contents->Option.getUnsafe
        let count = ref(0)
        Bus.subscribeToEvents(
          "sched-delete",
          async (_, _, _) => {
            count := count.contents + 1
          },
        )
        let _ = ops.createSchedule(
          [makeTopicResource("sched-delete")],
          {name: "test-delete", time: Every(Minutes(2)), payload: "{}"},
        )
        let _ = ops.deleteSchedule([], "test-delete")
        jest->advanceTimersByTime(2 * 60 * 1000)
        expect(count.contents)->toBe(0)
      },
    )
  })
})
