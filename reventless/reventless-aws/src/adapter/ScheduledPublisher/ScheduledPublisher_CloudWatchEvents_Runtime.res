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
  (queueResources, schedule) =>
    switch queueResources {
    | [] =>
      let err = "ScheduledPublisher_CloudWatchEvents_Runtime: createSchedule not possible: no Queue configured !"
      Effect.logError(err)
      ->Effect.flatMap(_ =>
        Effect.sync(() => JsError.throwWithMessage(err))
      )
      ->Effect.runPromise
    | resources =>
      let resource = resources->Array.getUnsafe(0) // FIXME
      Effect.promise(() =>
        PutRuleCommand.send(
          PutRuleCommand.make({
            name: schedule.name,
            scheduleExpression: schedule.rate->toScheduleExpression,
            roleArn: role.arn->Pulumi.Output.get,
            state: "ENABLED",
          }),
        )
      )
      ->Effect.flatMap(_ =>
        Effect.promise(() =>
          PutTargetsCommand.send(
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
        )
      )
      ->Effect.map(_ => ())
      ->Effect.runPromise
    }

let deleteSchedule: ReventlessCore.Scheduler.deleteSchedule = (queueResources, name) =>
  switch queueResources {
  | [] =>
    let err = "ScheduledPublisher_CloudWatchEvents_Runtime: deleteSchedule not possible: no Queue configured !"
    Effect.logError(err)
    ->Effect.flatMap(_ =>
      Effect.sync(() => JsError.throwWithMessage(err))
    )
    ->Effect.runPromise
  | resources =>
    let resource = resources->Array.getUnsafe(0) // FIXME
    Effect.promise(() =>
      RemoveTargetsCommand.send(
        RemoveTargetsCommand.make({
          rule: name,
          ids: [resource.name],
        }),
      )
    )
    ->Effect.flatMap(_ =>
      Effect.promise(() =>
        DeleteRuleCommand.send(
          DeleteRuleCommand.make({
            name: name,
          }),
        )
      )
    )
    ->Effect.map(_ => ())
    ->Effect.runPromise
  }
