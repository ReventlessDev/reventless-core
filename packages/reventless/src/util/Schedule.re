type create = (. Scheduler.schedule) => Js.Promise.t(unit);
type delete = (. /*~name:*/ string) => Js.Promise.t(unit);

exception ScheduleNotCreated(Scheduler.schedule, string, Js.Promise.error);
exception ScheduleNotDeleted(string, string, Js.Promise.error);

let forQueue = (name, queueId) =>
  name ++ "-" ++ (queueId |> Js.String.split("-"))[1];

let create: (Scheduler.t, Adapter.resource) => create =
  (scheduler, queue) =>
    (. schedule: Scheduler.schedule) => {
      let queueId = queue##name->OutputFailsafeRuntime.get;
      let name =
        schedule.name
        ->Js.String2.replace("^[\.\-_A-Za-z0-9]", "_")
        ->forQueue(queueId);
      let schedule = {...schedule, name};
      let target =
        Scheduler.{
          id: queue##name |> Pulumi.Output.get,
          urn: queue##urn |> Pulumi.Output.get,
        };
      let createSchedule = scheduler##createSchedule;
      createSchedule(. target, schedule)
      |> Js.Promise.then_(_ =>
           Js.log4(
             "ExtensionPoint.createSchedule: created",
             schedule,
             queueId,
             target,
           )
           |> Js.Promise.resolve
         )
      |> Js.Promise.catch(err => {
           Js.log4(
             "Task.createSchedule: couldn't create",
             schedule,
             queueId,
             err,
           );
           ScheduleNotCreated(schedule, queueId, err)->Js.Promise.reject;
         });
    };

let delete: (Scheduler.t, Adapter.resource) => delete =
  (scheduler, queue) =>
    (. name) => {
      let queueId = queue##name->OutputFailsafeRuntime.get;
      let name = name->forQueue(queueId);
      let target =
        Scheduler.{
          id: queue##name |> Pulumi.Output.get,
          urn: queue##urn |> Pulumi.Output.get,
        };
      let deleteSchedule = scheduler##deleteSchedule;
      deleteSchedule(. target, name)
      |> Js.Promise.then_(_ =>
           Js.log3("Task.deleteSchedule: deleted", name, queueId)
           |> Js.Promise.resolve
         )
      |> Js.Promise.catch(err => {
           Js.log4(
             "ExtensionPoint.deleteSchedule: couldn't delete",
             name,
             queueId,
             err,
           );
           ScheduleNotDeleted(name, queueId, err)->Js.Promise.reject;
         });
    };
