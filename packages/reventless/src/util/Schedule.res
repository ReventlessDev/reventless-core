open ReventlessSpec.Schedule

module DateCalc = {
  /*** Immutable functions to calculate new Dates without mutation the arguments */
  @new
  external dateFromDate: Date.t => Date.t = "Date"

  let addMinutes: (Date.t, int) => Date.t = (date, minutes) => {
    let result = date->dateFromDate
    result->Date.setUTCMinutes(result->Date.getUTCMinutes + minutes)
    result
  }

  let addDays: (Date.t, int) => Date.t = (date, days) => {
    let result = date->dateFromDate
    result->Date.setUTCDate(result->Date.getUTCDate + days)
    result
  }
}

let forQueue = (name, queueId) =>
  name->AWS.validateName ++ ("-" ++ queueId->Js.String2.split("-")->Array.getUnsafe(1))

let minutesFromNow = minutes => {
  let m = Date.make()->DateCalc.addMinutes(minutes)
  Single(
    m->Date.getUTCFullYear,
    m->Date.getUTCMonth + 1,
    m->Date.getUTCDate,
    m->Date.getUTCHours,
    m->Date.getUTCMinutes,
  )
}

let nextTime = (h: hour, m: minute) => {
  let now = Date.make()
  let today = {
    let epoch = Date.make()
    epoch->Date.setUTCHours(h)
    epoch->Date.setUTCMinutes(m)
    epoch->Date.setUTCSeconds(0)
    epoch
  }
  let tomorrow = today->DateCalc.addDays(1)
  today < now
    ? Single(
        tomorrow->Date.getUTCFullYear,
        tomorrow->Date.getUTCMonth + 1,
        tomorrow->Date.getUTCDate,
        tomorrow->Date.getUTCHours,
        tomorrow->Date.getUTCMinutes,
      )
    : Single(
        today->Date.getUTCFullYear,
        today->Date.getUTCMonth + 1,
        today->Date.getUTCDate,
        today->Date.getUTCHours,
        today->Date.getUTCMinutes,
      )
}

exception ScheduleNotCreated(schedule)
exception ScheduleNotDeleted(string)

let create = (scheduler: ReventlessSpec.Scheduler.t, queueResources) =>
  async schedule => {
    let name = schedule.name->AWS.validateName
    let schedule = {...schedule, name}
    let createSchedule = scheduler.createSchedule
    switch await createSchedule(queueResources, schedule) {
    | _ => Js.log2("Schedule.create: created", schedule)
    | exception err => {
        Js.log3("Schedule.create: couldn't create", schedule, err)
        raise(ScheduleNotCreated(schedule))
      }
    }
  }

let delete = (scheduler: ReventlessSpec.Scheduler.t, queueResources) =>
  async name => {
    let name = name->AWS.validateName
    let deleteSchedule = scheduler.deleteSchedule
    switch await deleteSchedule(queueResources, name) {
    | _ => Js.log2("Schedule.delete: deleted", name)
    | exception err => {
        Js.log3("Schedule.delete: couldn't delete", name, err)
        raise(ScheduleNotDeleted(name))
      }
    }
  }
