open ReventlessSpec.Schedule
open AwsSdk.CloudWatchEvents

let plural = count => count == 1 ? "" : "s"

let toScheduleExpression = x =>
  switch x {
  | Single(year, month, day, hour, minute) =>
    `cron(${minute->Belt.Int.toString} ${hour->Belt.Int.toString} ${day->Belt.Int.toString} ${month->Belt.Int.toString} ? ${year->Belt.Int.toString})`
  | Minutes(minutes) =>
    let plural = minutes->plural
    `rate(${minutes->Belt.Int.toString} minute${plural})`
  | Hours(hours) =>
    let plural = hours->plural
    `rate(${hours->Belt.Int.toString} hour${plural})`
  | Days(days) =>
    let plural = days->plural
    `rate(${days->Belt.Int.toString} day${plural})`
  | Daily(hour, minute) => `cron(${minute->Belt.Int.toString} ${hour->Belt.Int.toString} * * * *)`
  | Weekdays(hour, minute) =>
    `cron(${minute->Belt.Int.toString} ${hour->Belt.Int.toString} ? * MON-FRI *)`
  | WeekdaysAndSaturday(hour, minute) =>
    `cron(${minute->Belt.Int.toString} ${hour->Belt.Int.toString} ? * MON-SAT *)`
  }

let createSchedule: PulumiAws.IAM.Role.t => ReventlessSpec.Scheduler.createSchedule = role =>
  (. queueResources, schedule) =>
    switch queueResources {
    | [] =>
      let err = "ScheduledPublisher_CloudWatchEvents_Runtime: createSchedule not possible: no Queue configured !"
      Js.log(err)
      Js.Exn.raiseError(err)
    | resources =>
      let resource = resources[0] // FIXME
      putRule(
        ~name=schedule.name,
        ~scheduleExpression=schedule.rate->toScheduleExpression,
        ~roleArn=role["arn"]->Pulumi.Output.get,
        ~state="ENABLED",
        (),
      )
      |> Js.Promise.then_(_ =>
        putTarget(
          ~rule=schedule.name,
          ~arn=resource["urn"]->Pulumi.Output.get,
          ~id=resource["name"]->Pulumi.Output.get,
          ~input=schedule.payload,
        )
      )
      |> Js.Promise.then_(_ => Js.Promise.resolve())
    }

let deleteSchedule: ReventlessSpec.Scheduler.deleteSchedule = (. queueResources, name) =>
  switch queueResources {
  | [] =>
    let err = "ScheduledPublisher_CloudWatchEvents_Runtime: deleteSchedule not possible: no Queue configured !"
    Js.log(err)
    Js.Exn.raiseError(err)
  | resources =>
    let resource = resources[0] // FIXME
    removeTarget(~rule=name, ~id=resource["name"]->Pulumi.Output.get)
    |> Js.Promise.then_(_ => deleteRule(~name) |> Js.Promise.then_(_ => Js.Promise.resolve()))
    |> Js.Promise.then_(_ => Js.Promise.resolve())
  }
