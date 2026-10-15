open Reventless.Schedule

let forChannel = (~name, ~channelId, ~resourceNaming: ReventlessInfra.ResourceNaming.operations) =>
  name->resourceNaming.validateName ++ ("-" ++ channelId->String.split("-")->Array.getUnsafe(1))

let minutesFromNow = minutes => Once({moment: After(Minutes(minutes))})

exception ScheduleNotCreated(schedule)
exception ScheduleNotDeleted(string)

let create = (
  ~scheduler: Scheduler.operations,
  ~channelResources,
  ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
) =>
  async schedule => {
    let name = schedule.name->resourceNaming.validateName
    let schedule = {...schedule, name}
    let createSchedule = scheduler.createSchedule
    let exit = await Effect.tryPromise(
      ~catch=err => Util.Error.messageFromUnknown(err, "schedule create"),
      () => createSchedule(channelResources, schedule),
    )
    ->Effect.tap(_ =>
      EffectLogger.logInfo(
        ~comp=__MODULE__,
        `create: created ${schedule->JSON.stringifyAny->Option.getOr("")}`,
      )
    )
    ->Effect.runPromiseExit
    if !(exit->Exit.isSuccess) {
      let errMsg =
        exit->Exit.match(~onFailure=cause => cause->Cause.pretty, ~onSuccess=_ => "unknown")
      EffectLogger.logError(
        ~comp=__MODULE__,
        `create: couldn't create ${schedule
          ->JSON.stringifyAny
          ->Option.getOr("")}: ${errMsg}`,
      )->Effect.runSync
      throw(ScheduleNotCreated(schedule))
    }
  }

let delete = (
  ~scheduler: Scheduler.operations,
  ~channelResources,
  ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
) =>
  async name => {
    let name = name->resourceNaming.validateName
    let deleteSchedule = scheduler.deleteSchedule
    let exit = await Effect.tryPromise(
      ~catch=err => Util.Error.messageFromUnknown(err, "schedule delete"),
      () => deleteSchedule(channelResources, name),
    )
    ->Effect.tap(_ => EffectLogger.logInfo(~comp=__MODULE__, `delete: deleted ${name}`))
    ->Effect.runPromiseExit
    if !(exit->Exit.isSuccess) {
      let errMsg =
        exit->Exit.match(~onFailure=cause => cause->Cause.pretty, ~onSuccess=_ => "unknown")
      EffectLogger.logError(
        ~comp=__MODULE__,
        `delete: couldn't delete ${name}: ${errMsg}`,
      )->Effect.runSync
      throw(ScheduleNotDeleted(name))
    }
  }
