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
  let timers = LocalTimers.make()

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
      let topicName = switch channelResources {
      | [] => ""
      | resources => (resources->Array.getUnsafe(0)).name
      }
      let payloadJson = switch schedule.payload->JSON.parseOrThrow {
      | json => json
      | exception _ => schedule.payload->JSON.Encode.string
      }
      timers->LocalTimers.start(schedule.name, schedule.time, ~setAt=Date.now(), ~fire=_ =>
        Bus.publishEvent(topicName, "Scheduler", scheduleMeta, payloadJson)->ignore
      )
    }

    let deleteSchedule: ReventlessInfra.Scheduler.deleteSchedule = async (_, name) =>
      timers->LocalTimers.stop(name)

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
  let reset = () => timers->LocalTimers.reset
}
