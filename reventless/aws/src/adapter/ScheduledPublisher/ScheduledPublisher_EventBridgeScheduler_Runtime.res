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

let putSchedule = async (~roleArn, ~targetArn, schedule: Reventless.Schedule.schedule) => {
  ReventlessCore.ScheduleTime.validate(schedule.time)
  let input = schedule->scheduleInput(~roleArn, ~targetArn, ~setAt=Date.now())
  switch await CreateScheduleCommand.make(input)->CreateScheduleCommand.send {
  | _ => ()
  | exception JsExn(err) if err->ErrorName.is(ErrorName.conflict) =>
    let _ = await UpdateScheduleCommand.make(input)->UpdateScheduleCommand.send
  }
}

let removeSchedule = async (~roleArn, name) =>
  switch await DeleteScheduleCommand.make({
    name,
    groupName: roleArn->groupOfRoleArn,
  })->DeleteScheduleCommand.send {
  | _ => ()
  | exception JsExn(err) if err->ErrorName.is(ErrorName.resourceNotFound) => ()
  }

/** Creates the schedule, or replaces the one of that name, as a classic rule's `PutRule` did. */
let createSchedule = (~roleArn: string): ReventlessCore.Scheduler.createSchedule =>
  async (queueResources, schedule) =>
    switch queueResources {
    | [] => await failWithoutQueue("createSchedule")
    | resources =>
      let resource = resources->Array.getUnsafe(0) // FIXME
      await putSchedule(~roleArn, ~targetArn=resource.urn, schedule)
    }

/** Deletes the schedule; one already gone, such as a once-only time that fired, is no error. */
let deleteSchedule = (~roleArn: string): ReventlessCore.Scheduler.deleteSchedule =>
  async (queueResources, name) =>
    switch queueResources {
    | [] => await failWithoutQueue("deleteSchedule")
    | _ => await removeSchedule(~roleArn, name)
    }

// ── An automation's schedules ───────────────────────────────────────────────

let validName = /^[0-9a-zA-Z\-_.]{1,64}$/

/**
The platform name of an automation's schedule: `<slice>.<key>`, or, when that is too
long or holds a character EventBridge refuses, the slice's name cut to 40 characters
and a hash of the key.
*/
let tickScheduleName = (~slice, ~key) => {
  let name = `${slice}.${key}`
  validName->RegExp.test(name)
    ? name
    : {
        let hash =
          NodeCrypto.createHash("sha256")
          ->NodeCrypto.hashUpdate(key)
          ->NodeCrypto.hashDigest("hex")
          ->String.slice(~start=0, ~end=16)
        `${slice->String.slice(~start=0, ~end=40)}.${hash}`
      }
}

/** What the Scheduler sends the automation Lambda: the slice, the key and the scheduled time. */
let tickInput = (~slice, ~key) =>
  JSON.Encode.object(
    Dict.fromArray([
      (
        "reventlessTick",
        JSON.Encode.object(
          Dict.fromArray([
            ("slice", slice->JSON.Encode.string),
            ("key", key->JSON.Encode.string),
            ("at", "<aws.scheduler.scheduled-time>"->JSON.Encode.string),
          ]),
        ),
      ),
    ]),
  )->JSON.stringify

/** Sets the slice's schedule of that key, invoking `lambdaArn` with `tickInput` at each firing. */
let putTickSchedule = (~roleArn, ~lambdaArn, ~slice, ~key, time) =>
  putSchedule(
    ~roleArn,
    ~targetArn=lambdaArn,
    {name: tickScheduleName(~slice, ~key), time, payload: tickInput(~slice, ~key)},
  )

/** Removes the slice's schedule of that key; one it does not have is no error. */
let deleteTickSchedule = (~roleArn, ~slice, ~key) =>
  removeSchedule(~roleArn, tickScheduleName(~slice, ~key))
