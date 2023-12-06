open ReventlessSpec.Schedule
open ReventlessSpec.Adapter
open MomentRe
open Moment

let forQueue = (name, queueId) =>
  name->AWS.validateName ++ ("-" ++ (queueId->Js.String2.split("-"))[1])

let minutesFromNow = minutes => {
  let m = momentNow()->add(~duration=duration(minutes->float_of_int, #minutes))
  Single(m->year, m->month + 1, m->date, m->hour, m->minute)
}

let nextTime = (h: hour, m: minute) => {
  let now = momentNow()
  let today = now |> setHour(h) |> setMinute(m) |> setSecond(0)
  let tomorrow = today->add(~duration=duration(1.0, #days))
  today->isBefore(now)
    ? Single(tomorrow->year, tomorrow->month + 1, tomorrow->date, tomorrow->hour, tomorrow->minute)
    : Single(today->year, today->month + 1, today->date, today->hour, today->minute)
}

exception ScheduleNotCreated(schedule)
exception ScheduleNotDeleted(string)

let create = (scheduler, queueResources) => async (. schedule) => {
  let name = schedule.name->AWS.validateName
  let schedule = {...schedule, name}
  let createSchedule = scheduler["createSchedule"]
  switch await createSchedule(. queueResources, schedule) {
  | _ => Js.log2("Schedule.create: created", schedule)
  | exception err => {
      Js.log3("Schedule.create: couldn't create", schedule, err)
      raise(ScheduleNotCreated(schedule))
    }
  }
}

let delete: (ReventlessSpec.Scheduler.t, array<resource>) => delete = (
  scheduler,
  queueResources,
) => async (. name) => {
  let name = name->AWS.validateName
  let deleteSchedule = scheduler["deleteSchedule"]
  switch await deleteSchedule(. queueResources, name) {
  | _ => Js.log2("Schedule.delete: deleted", name)
  | exception err => {
      Js.log3("Schedule.delete: couldn't delete", name, err)
      raise(ScheduleNotDeleted(name))
    }
  }
}
