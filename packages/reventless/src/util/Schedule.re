open ReventlessSpec.Schedule;
open ReventlessSpec.Scheduler;
open ReventlessSpec.Adapter;

let forQueue = (name, queueId) =>
  name->AWS.validateName ++ "-" ++ (queueId |> Js.String.split("-"))[1];

let minutesFromNow = minutes => {
  open MomentRe;
  open Moment;
  let m =
    momentNow()
    ->Moment.add(~duration=duration(minutes->float_of_int, `minutes));
  Single(m->year, m->month + 1, m->date, m->hour, m->minute);
};

let create: (Scheduler.t, resource) => create =
  (scheduler, queue) =>
    (. schedule: schedule) => {
      let queueId = queue##name->OutputFailsafeRuntime.get;
      let name = schedule.name->forQueue(queueId);
      let schedule = {...schedule, name};
      let target = {
        id: queue##name |> Pulumi.Output.get,
        urn: queue##urn |> Pulumi.Output.get,
      };
      let createSchedule = scheduler##createSchedule;
      createSchedule(. target, schedule)
      |> Js.Promise.then_(_ =>
           Js.log4("Schedule.create: created", schedule, queueId, target)
           |> Js.Promise.resolve
         )
      |> Js.Promise.catch(err => {
           Js.log4(
             "Schedule.create: couldn't create",
             schedule,
             queueId,
             err,
           );
           ScheduleNotCreated(schedule, queueId, err)->Js.Promise.reject;
         });
    };

let delete: (Scheduler.t, resource) => delete =
  (scheduler, queue) =>
    (. name) => {
      let queueId = queue##name->OutputFailsafeRuntime.get;
      let name = name->forQueue(queueId);
      let target = {
        id: queue##name |> Pulumi.Output.get,
        urn: queue##urn |> Pulumi.Output.get,
      };
      let deleteSchedule = scheduler##deleteSchedule;
      deleteSchedule(. target, name)
      |> Js.Promise.then_(_ =>
           Js.log3("Schedule.delete: deleted", name, queueId)
           |> Js.Promise.resolve
         )
      |> Js.Promise.catch(err => {
           Js.log4("Schedule.delete: couldn't delete", name, queueId, err);
           ScheduleNotDeleted(name, queueId, err)->Js.Promise.reject;
         });
    };
