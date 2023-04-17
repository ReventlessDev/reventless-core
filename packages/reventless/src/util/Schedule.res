open ReventlessSpec.Schedule
open ReventlessSpec.Adapter

let forQueue = (name, queueId) =>
  name->AWS.validateName ++ ("-" ++ (queueId |> Js.String.split("-"))[1])

let minutesFromNow = minutes => {
  open MomentRe
  open Moment
  let m = momentNow()->Moment.add(~duration=duration(minutes->float_of_int, #minutes))
  Single(m->year, m->month + 1, m->date, m->hour, m->minute)
}

exception ScheduleNotCreated(schedule, Js.Promise.error)
exception ScheduleNotDeleted(string, Js.Promise.error)

let create = (scheduler, queueResources, . schedule) => {
  let name = schedule.name->AWS.validateName
  let schedule = {...schedule, name: name}
  let createSchedule = scheduler["createSchedule"]
  createSchedule(. queueResources, schedule)
  |> Js.Promise.then_(_ => Js.log2("Schedule.create: created", schedule)->Js.Promise.resolve)
  |> Js.Promise.catch(err => {
    Js.log3("Schedule.create: couldn't create", schedule, err)
    ScheduleNotCreated(schedule, err)->Js.Promise.reject
  })
}

let delete: (Scheduler.t, array<resource>) => delete = (scheduler, queueResources, . name) => {
  let name = name->AWS.validateName
  let deleteSchedule = scheduler["deleteSchedule"]
  deleteSchedule(. queueResources, name)
  |> Js.Promise.then_(_ => Js.log2("Schedule.delete: deleted", name)->Js.Promise.resolve)
  |> Js.Promise.catch(err => {
    Js.log3("Schedule.delete: couldn't delete", name, err)
    ScheduleNotDeleted(name, err)->Js.Promise.reject
  })
}
