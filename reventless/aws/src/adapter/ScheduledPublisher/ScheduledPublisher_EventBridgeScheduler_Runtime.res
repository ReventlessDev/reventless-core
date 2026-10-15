open AwsSdk.EventBridgeScheduler

// The schedule group is named after the scheduler role, so the role ARN every caller
// already receives also names the group its schedules go into. Pulumi names the role
// `<roleName>-<suffix>`.
let roleName = "SchedulerRole"

let groupOfRoleArn = roleArn => roleArn->String.split("/")->Array.at(-1)->Option.getOr("")

/** What a Lambda that sets schedules is granted: these actions on `schedulesOfRoleArn`. */
let manageActions = [
  "scheduler:CreateSchedule",
  "scheduler:UpdateSchedule",
  "scheduler:DeleteSchedule",
]

/** The schedules in the group of the scheduler role `roleArn` (`arn:aws:iam::<account>:role/<name>`). */
let schedulesOfRoleArn = roleArn => {
  let account = roleArn->String.split(":")->Array.get(4)->Option.getOr("*")
  `arn:aws:scheduler:*:${account}:schedule/${roleArn->groupOfRoleArn}/*`
}

/** The schedules in every scheduler group of `account`, for a grant that cannot know the role. */
let schedulesOfAccount = account => `arn:aws:scheduler:*:${account}:schedule/${roleName}-*/*`

// A FIFO queue refuses a message without a group id.
let isFifoQueue = arn => arn->String.endsWith(".fifo")

let scheduleInput = (
  ~roleArn,
  ~targetArn,
  ~setAt,
  schedule: Reventless.Schedule.schedule,
): scheduleInput => {
  let aws = schedule.time->ReventlessCore.ScheduleTime.toAws(~setAt)
  {
    name: schedule.name,
    groupName: roleArn->groupOfRoleArn,
    scheduleExpression: aws.expression,
    scheduleExpressionTimezone: ?aws.timezone,
    startDate: ?(aws.startDate->Option.map(Date.fromTime)),
    flexibleTimeWindow: {mode: "OFF"},
    actionAfterCompletion: aws.deleteAfterCompletion ? "DELETE" : "NONE",
    target: {
      arn: targetArn,
      roleArn,
      input: schedule.payload,
      sqsParameters: ?(targetArn->isFifoQueue ? Some({messageGroupId: schedule.name}) : None),
    },
  }
}

let failWithoutQueue = action => {
  let err = `${action} not possible: no Queue configured !`
  ReventlessCore.EffectLogger.logError(~comp=__MODULE__, err)
  ->Effect.flatMap(_ => Effect.sync(() => JsError.throwWithMessage(err)))
  ->Effect.runPromise
}

/** Creates the schedule, or replaces the one of that name, as a classic rule's `PutRule` did. */
let createSchedule = (~roleArn: string): ReventlessCore.Scheduler.createSchedule =>
  async (queueResources, schedule) =>
    switch queueResources {
    | [] => await failWithoutQueue("createSchedule")
    | resources =>
      ReventlessCore.ScheduleTime.validate(schedule.time)
      let resource = resources->Array.getUnsafe(0) // FIXME
      let input = schedule->scheduleInput(~roleArn, ~targetArn=resource.urn, ~setAt=Date.now())
      switch await CreateScheduleCommand.make(input)->CreateScheduleCommand.send {
      | _ => ()
      | exception JsExn(err) if err->ErrorName.is(ErrorName.conflict) =>
        let _ = await UpdateScheduleCommand.make(input)->UpdateScheduleCommand.send
      }
    }

/** Deletes the schedule; one already gone, such as a once-only time that fired, is no error. */
let deleteSchedule = (~roleArn: string): ReventlessCore.Scheduler.deleteSchedule =>
  async (queueResources, name) =>
    switch queueResources {
    | [] => await failWithoutQueue("deleteSchedule")
    | _ =>
      switch await DeleteScheduleCommand.make({
        name,
        groupName: roleArn->groupOfRoleArn,
      })->DeleteScheduleCommand.send {
      | _ => ()
      | exception JsExn(err) if err->ErrorName.is(ErrorName.resourceNotFound) => ()
      }
    }
