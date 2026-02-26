open Reventless.Schedule
open AwsSdk.CloudWatchEvents

let plural = count => count == 1 ? "" : "s"

let toScheduleExpression = x =>
  switch x {
  | Single(year, month, day, hour, minute) =>
    `cron(${minute->Int.toString} ${hour->Int.toString} ${day->Int.toString} ${month->Int.toString} ? ${year->Int.toString})`
  | Minutes(minutes) =>
    let plural = minutes->plural
    `rate(${minutes->Int.toString} minute${plural})`
  | Hours(hours) =>
    let plural = hours->plural
    `rate(${hours->Int.toString} hour${plural})`
  | Days(days) =>
    let plural = days->plural
    `rate(${days->Int.toString} day${plural})`
  | Daily(hour, minute) => `cron(${minute->Int.toString} ${hour->Int.toString} * * * *)`
  | Weekdays(hour, minute) => `cron(${minute->Int.toString} ${hour->Int.toString} ? * MON-FRI *)`
  | WeekdaysAndSaturday(hour, minute) =>
    `cron(${minute->Int.toString} ${hour->Int.toString} ? * MON-SAT *)`
  }

let createSchedule: PulumiAws.IAM.Role.t => ReventlessCore.Scheduler.createSchedule = role =>
  async (queueResources, schedule) =>
    switch queueResources {
    | [] =>
      let err = "ScheduledPublisher_CloudWatchEvents_Runtime: createSchedule not possible: no Queue configured !"
      Console.log(err)
      JsError.throwWithMessage(err)
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
              arn: resource.urn,
              id: resource.name,
              input: schedule.payload,
            },
          ],
        }),
      )
    }

let deleteSchedule: ReventlessCore.Scheduler.deleteSchedule = async (queueResources, name) =>
  switch queueResources {
  | [] =>
    let err = "ScheduledPublisher_CloudWatchEvents_Runtime: deleteSchedule not possible: no Queue configured !"
    Console.log(err)
    JsError.throwWithMessage(err)
  | resources =>
    let resource = resources->Array.getUnsafe(0) // FIXME
    let _ = await RemoveTargetsCommand.send(
      RemoveTargetsCommand.make({
        rule: name,
        ids: [resource.name],
      }),
    )
    let _ = DeleteRuleCommand.send(
      DeleteRuleCommand.make({
        name: name,
      }),
    )
  }
