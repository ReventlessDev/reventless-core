// Unit tests for LocalScheduledPublisher.
// Uses fake timers, which also fix Date.now, to check each shape of a time fires when
// ScheduleTime says it does.

open JestGlobals

type jestObj
@module("@jest/globals") external jest: jestObj = "jest"
@send external useFakeTimers: jestObj => unit = "useFakeTimers"
@send external useRealTimers: jestObj => unit = "useRealTimers"
@send external advanceTimersByTime: (jestObj, float) => unit = "advanceTimersByTime"
@send external setSystemTime: (jestObj, float) => unit = "setSystemTime"

let _ = beforeAll(() => {
  jest->useFakeTimers
})

// Pulumi mock (needed for Pulumi.Output.make in ScheduledPublisher)
let _ = TestRunner.setup()

let _ = afterAll(() => {
  jest->useRealTimers
})

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

let minute = 60_000.
let hour = 60. *. minute
let day = 24. *. hour
let at = iso => Date.fromString(iso)->Date.getTime

// Two microtask ticks: publishEvent uses Effect.all(concurrency=unbounded) which forks
// child fibers — one tick for the child fiber to offer to the Queue, a second for the
// drain fiber to run the callback.
let flush = async () => {
  let _ = await Promise.resolve()
  let _ = await Promise.resolve()
}

let advance = async ms => {
  jest->advanceTimersByTime(ms)
  await flush()
}

module TestBus = LocalBus.Make()
module SP = LocalScheduledPublisher.Make(TestBus)

let topicCount = ref(0)
let fired = topic => {
  let count = ref(0)
  TestBus.subscribeToEvents(topic, async (_, _, _) => {
    count := count.contents + 1
  })
  count
}

// A fresh topic per test, so a subscriber never sees another test's firings.
let schedule = async (~now, time) => {
  jest->setSystemTime(now->at)
  topicCount := topicCount.contents + 1
  let topic = `sched-topic-${topicCount.contents->Int.toString}`
  let count = fired(topic)
  let ops = await SP.make(~name="scheduler", ~opts={}).operations->TestRunner.resolve
  await ops.createSchedule([makeTopicResource(topic)], {name: topic, time, payload: "{}"})
  (ops, topic, count)
}

describe("LocalScheduledPublisher", () => {
  let _ = afterEach(() => SP.reset())

  describe("Every", () => {
    testPromise(
      "fires one interval after it is set, and again each interval",
      async () => {
        let (_, _, count) = await schedule(~now="2026-10-16T10:00:00Z", Every(Minutes(3)))
        await advance(3. *. minute -. 1.)
        expect(count.contents)->toBe(0)
        await advance(1.)
        expect(count.contents)->toBe(1)
        await advance(3. *. minute)
        expect(count.contents)->toBe(2)
      },
    )

    testPromise(
      "Hours(n) fires after n hours",
      async () => {
        let (_, _, count) = await schedule(~now="2026-10-16T10:00:00Z", Every(Hours(2)))
        await advance(2. *. hour)
        expect(count.contents)->toBe(1)
      },
    )
  })

  describe("Calendar", () => {
    testPromise(
      "fires at the wall-clock time each day, not 24 hours after it is set",
      async () => {
        let (_, _, count) = await schedule(
          ~now="2026-10-16T05:58:00Z",
          Calendar({calendar: Daily({hour: 6, minute: 0})}),
        )
        await advance(2. *. minute)
        expect(count.contents)->toBe(1)
        await advance(day)
        expect(count.contents)->toBe(2)
      },
    )

    testPromise(
      "skips a day whose time falls in the hour daylight saving skips",
      async () => {
        let (_, _, count) = await schedule(
          ~now="2027-03-27T12:00:00Z",
          Calendar({calendar: Daily({hour: 2, minute: 30}), zone: "Europe/Berlin"}),
        )
        // 28 March fires; 29 March has no 02:30 in Berlin; 30 March fires
        await advance(at("2027-03-29T12:00:00Z") -. at("2027-03-27T12:00:00Z"))
        expect(count.contents)->toBe(1)
        await advance(at("2027-03-30T12:00:00Z") -. at("2027-03-29T12:00:00Z"))
        expect(count.contents)->toBe(2)
      },
    )

    testPromise(
      "reaches a firing further away than a timer can wait",
      async () => {
        let (_, _, count) = await schedule(
          ~now="2026-10-16T10:00:00Z",
          Calendar({calendar: Yearly({month: 1, day: 1, hour: 6, minute: 0})}),
        )
        await advance(at("2027-01-01T05:59:00Z") -. at("2026-10-16T10:00:00Z"))
        expect(count.contents)->toBe(0)
        await advance(minute)
        expect(count.contents)->toBe(1)
      },
    )
  })

  describe("Once", () => {
    testPromise(
      "fires once, a period after it is set",
      async () => {
        let (_, _, count) = await schedule(
          ~now="2026-10-16T10:00:00Z",
          Once({moment: After(Minutes(10))}),
        )
        await advance(10. *. minute)
        expect(count.contents)->toBe(1)
        await advance(day)
        expect(count.contents)->toBe(1)
      },
    )

    testPromise(
      "never fires at a moment already past",
      async () => {
        let (_, _, count) = await schedule(
          ~now="2026-10-16T10:00:00Z",
          Once({moment: At({year: 2024, month: 1, day: 1, hour: 0, minute: 0})}),
        )
        await advance(day)
        expect(count.contents)->toBe(0)
      },
    )
  })

  describe("createSchedule", () => {
    testPromise(
      "replaces a schedule of the same name",
      async () => {
        let (ops, topic, count) = await schedule(~now="2026-10-16T10:00:00Z", Every(Minutes(1)))
        await ops.createSchedule(
          [makeTopicResource(topic)],
          {name: topic, time: Every(Minutes(5)), payload: "{}"},
        )
        await advance(5. *. minute)
        expect(count.contents)->toBe(1)
      },
    )

    testPromise(
      "refuses a time that cannot fire",
      async () => {
        let ops = await SP.make(~name="scheduler", ~opts={}).operations->TestRunner.resolve
        let refused = switch await ops.createSchedule(
          [makeTopicResource("refused")],
          {
            name: "refused",
            time: Calendar({calendar: Daily({hour: 25, minute: 0}), zone: "Mars/Base"}),
            payload: "{}",
          },
        ) {
        | _ => false
        | exception ReventlessCore.ScheduleTime.InvalidTime(_) => true
        }
        expect(refused)->toBe(true)
      },
    )
  })

  describe("deleteSchedule", () => {
    testPromise(
      "stops a schedule; advancing timers does not fire it",
      async () => {
        let (ops, topic, count) = await schedule(~now="2026-10-16T10:00:00Z", Every(Minutes(1)))
        await ops.deleteSchedule([], topic)
        await advance(minute)
        expect(count.contents)->toBe(0)
      },
    )
  })

  describe("reset", () => {
    testPromise(
      "clears all active timers; subsequent advance does not fire",
      async () => {
        let (_, _, count) = await schedule(~now="2026-10-16T10:00:00Z", Every(Minutes(5)))
        SP.reset()
        await advance(5. *. minute)
        expect(count.contents)->toBe(0)
      },
    )
  })
})
