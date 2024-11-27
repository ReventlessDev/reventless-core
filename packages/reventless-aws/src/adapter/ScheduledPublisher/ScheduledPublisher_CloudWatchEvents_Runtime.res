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
  async (queueResources, schedule) =>
    switch queueResources {
    | [] =>
      let err = "ScheduledPublisher_CloudWatchEvents_Runtime: createSchedule not possible: no Queue configured !"
      Js.log(err)
      Js.Exn.raiseError(err)
    | resources =>
      let resource = resources->Array.getUnsafe(0) // FIXME
      let _ = await PutRuleCommand.send(
        PutRuleCommand.make({
          name: schedule.name,
          scheduleExpression: schedule.rate->toScheduleExpression,
          roleArn: role.arn->Pulumi.Output.get,
          state: "ENABLED",
        }),
      )
      let _ = await PutTargetsCommand.send(
        PutTargetsCommand.make({
          rule: schedule.name,
          targets: [
            {
              arn: resource.urn->Pulumi.Output.get,
              id: resource.name->Pulumi.Output.get,
              input: schedule.payload,
            },
          ],
        }),
      )
    }

let deleteSchedule: ReventlessSpec.Scheduler.deleteSchedule = async (queueResources, name) =>
  switch queueResources {
  | [] =>
    let err = "ScheduledPublisher_CloudWatchEvents_Runtime: deleteSchedule not possible: no Queue configured !"
    Js.log(err)
    Js.Exn.raiseError(err)
  | resources =>
    let resource = resources->Array.getUnsafe(0) // FIXME
    let _ = await RemoveTargetsCommand.send(
      RemoveTargetsCommand.make({
        rule: name,
        ids: [resource.name->Pulumi.Output.get],
      }),
    )
    let _ = DeleteRuleCommand.send(
      DeleteRuleCommand.make({
        name: name,
      }),
    )
  }
