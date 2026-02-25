// In-memory ScheduledPublisher — satisfies Scheduler_Adapter.ScheduledPublisher.
//
// createSchedule: sets up a setInterval that fires Bus.publishEvent when the schedule triggers.
// deleteSchedule: clears the interval.
//
// The schedule.payload is published as the event body. For Single(…) schedules a
// one-shot setTimeout is used; all recurring rates use setInterval.
//
// Usage: create a Scheduler with Scheduler_Builder.Make(ScheduledPublisher_InMemory.Make(Bus))
// and pass the resulting component to Plugin_Builder or Task_Builder.

module Make = (Bus: InMemory_Bus.T) => {
  type timerHandle

  @val
  external setIntervalJs: (unit => unit, int) => timerHandle = "setInterval"
  @val
  external setTimeoutJs: (unit => unit, int) => timerHandle = "setTimeout"
  @val
  external clearTimerJs: timerHandle => unit = "clearTimeout"

  let activeTimers: ref<dict<timerHandle>> = ref(Dict.make())

  let rateToMs = (rate: ReventlessSpec.Schedule.rate) =>
    switch rate {
    | Minutes(n) => n * 60 * 1000
    | Hours(n) => n * 60 * 60 * 1000
    | Days(n) => n * 24 * 60 * 60 * 1000
    | Daily(_, _) => 24 * 60 * 60 * 1000
    | Weekdays(_, _) => 24 * 60 * 60 * 1000
    | WeekdaysAndSaturday(_, _) => 24 * 60 * 60 * 1000
    | Single(_, _, _, _, _) => 0
    }

  let isSingleShot = rate =>
    switch rate {
    | ReventlessSpec.Schedule.Single(_, _, _, _, _) => true
    | _ => false
    }

  let scheduleMeta: Reventless.Message.meta = {
    service: "Scheduler",
    time: "",
    ip: "",
    user: "Scheduler",
    msgId: "",
    correlationId: "",
  }

  let make: Reventless.Scheduler_Adapter.scheduledPublisherMaker = (~name as _, ~opts as _) => {
    let createSchedule: ReventlessSpec.Scheduler.createSchedule = async (
      channelResources,
      schedule,
    ) => {
      let topicName = switch channelResources {
      | [] => ""
      | resources => (resources->Array.getUnsafe(0)).name
      }
      let payloadJson = switch schedule.payload->JSON.parseOrThrow {
      | json => json
      | exception _ => schedule.payload->JSON.Encode.string
      }
      let fire = () =>
        Bus.publishEvent(topicName, "Scheduler", scheduleMeta, payloadJson)->ignore
      let handle =
        if schedule.rate->isSingleShot {
          setTimeoutJs(fire, 0)
        } else {
          setIntervalJs(fire, rateToMs(schedule.rate))
        }
      activeTimers.contents->Dict.set(schedule.name, handle)
    }

    let deleteSchedule: ReventlessSpec.Scheduler.deleteSchedule = async (_, name) => {
      switch activeTimers.contents->Dict.get(name) {
      | Some(handle) =>
        clearTimerJs(handle)
        activeTimers.contents->Dict.delete(name)
      | None => ()
      }
    }

    {
      resource: {
        ReventlessSpec.Adapter.service: "InMemory"->Pulumi.Output.make,
        name: ""->Pulumi.Output.make,
        id: ""->Pulumi.Output.make,
        urn: ""->Pulumi.Output.make,
        info: ""->Pulumi.Output.make,
      },
      operations: ({
        createSchedule,
        deleteSchedule,
      }: ReventlessSpec.Scheduler.operations)->Pulumi.Output.make,
    }
  }

  // Clear all active timers — call in afterAll/afterEach for test isolation.
  let reset = () => {
    activeTimers.contents->Dict.valuesToArray->Array.forEach(clearTimerJs)
    activeTimers.contents = Dict.make()
  }
}
