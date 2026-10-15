// In-memory ScheduledPublisher — satisfies Scheduler_Adapter.ScheduledPublisher.
//
// createSchedule waits for each firing `ScheduleTime.nextFiring` names and publishes the
// payload as an event on the first channel resource; a once-only time fires once, one
// already past never. A second createSchedule under the same name replaces the first,
// as on AWS. deleteSchedule stops it.
//
// Usage: create a Scheduler with Scheduler_Builder.Make(LocalScheduledPublisher.Make(Bus))
// and pass the resulting component to Plugin_Builder or Task_Builder.

module Make = (Bus: LocalBus.T) => {
  type timerHandle

  @val
  external setTimeoutJs: (unit => unit, float) => timerHandle = "setTimeout"
  @val
  external clearTimerJs: timerHandle => unit = "clearTimeout"

  let activeTimers: ref<dict<timerHandle>> = ref(Dict.make())

  // Node fires a delay above 2^31 - 1 ms at once, so a far firing is reached a day at a time.
  let maxWaitMs = 86_400_000.

  let stop = name =>
    switch activeTimers.contents->Dict.get(name) {
    | Some(handle) =>
      clearTimerJs(handle)
      activeTimers.contents->Dict.delete(name)
    | None => ()
    }

  let rec waitUntil = (name, at, fire) => {
    let delay = at -. Date.now()
    let handle =
      delay > maxWaitMs
        ? setTimeoutJs(() => waitUntil(name, at, fire), maxWaitMs)
        : setTimeoutJs(fire, Math.max(delay, 0.))
    activeTimers.contents->Dict.set(name, handle)
  }

  let rec arm = (name, time, ~after, ~publish) =>
    switch ReventlessCore.ScheduleTime.nextFiring(time, ~after) {
    | None => activeTimers.contents->Dict.delete(name)
    | Some(at) =>
      waitUntil(name, at, () => {
        publish()
        arm(name, time, ~after=at, ~publish)
      })
    }

  let scheduleMeta: ReventlessCore.Message.meta = {
    service: "Scheduler",
    time: "",
    ip: "",
    user: "Scheduler",
    msgId: "",
    correlationId: "",
  }

  let make: ReventlessCore.Scheduler_Adapter.scheduledPublisherMaker = (~name as _, ~opts as _) => {
    let createSchedule: ReventlessInfra.Scheduler.createSchedule = async (
      channelResources,
      schedule,
    ) => {
      ReventlessCore.ScheduleTime.validate(schedule.time)
      let topicName = switch channelResources {
      | [] => ""
      | resources => (resources->Array.getUnsafe(0)).name
      }
      let payloadJson = switch schedule.payload->JSON.parseOrThrow {
      | json => json
      | exception _ => schedule.payload->JSON.Encode.string
      }
      let publish = () =>
        Bus.publishEvent(topicName, "Scheduler", scheduleMeta, payloadJson)->ignore
      let setAt = Date.now()
      stop(schedule.name)
      arm(
        schedule.name,
        schedule.time->ReventlessCore.ScheduleTime.resolveOnce(~from=setAt),
        ~after=setAt,
        ~publish,
      )
    }

    let deleteSchedule: ReventlessInfra.Scheduler.deleteSchedule = async (_, name) => stop(name)

    {
      resource: ReventlessInfra.Adapter.make(
        ~name=""->Pulumi.Output.make,
        ~id=""->Pulumi.Output.make,
        ~urn=""->Pulumi.Output.make,
        ~service="memory:InMemory"->Pulumi.Output.make,
      ),
      operations: (
        {
          createSchedule,
          deleteSchedule,
        }: ReventlessInfra.Scheduler.operations
      )->Pulumi.Output.make,
    }
  }

  // Clear all active timers — call in afterAll/afterEach for test isolation.
  let reset = () => {
    activeTimers.contents->Dict.valuesToArray->Array.forEach(clearTimerJs)
    activeTimers.contents = Dict.make()
  }
}
