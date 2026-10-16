open JestGlobals
open AwsSdk.EventBridgeScheduler

// What EventBridge Scheduler is given for a schedule; the times themselves are
// ScheduleTime's, tested in core.

module Runtime = ScheduledPublisher_EventBridgeScheduler_Runtime

let roleArn = "arn:aws:iam::123456789012:role/SchedulerRole-1a2b3c4"
let queueArn = "arn:aws:sqs:eu-central-1:123456789012:CatalogAggrCmdTopic-5150050"
let fifoArn = "arn:aws:sqs:eu-central-1:123456789012:CatalogAggrCmdTopic-5150050.fifo"
let setAt = Date.fromString("2026-10-15T14:02:00Z")->Date.getTime

let input = (~targetArn=queueArn, time) =>
  {Reventless.Schedule.name: "disconnect-p1", time, payload: `{"a":1}`}->Runtime.scheduleInput(
    ~roleArn,
    ~targetArn,
    ~setAt,
  )

describe("ScheduledPublisher_EventBridgeScheduler_Runtime", () => {
  testSync("puts the schedule into the group named after the role", () => {
    let i = input(Every(Minutes(5)))
    expect(i.groupName)->toEqual(Some("SchedulerRole-1a2b3c4"))
    expect(i.target.roleArn)->toBe(roleArn)
    expect(i.target.input)->toEqual(Some(`{"a":1}`))
    expect(i.flexibleTimeWindow.mode)->toBe("OFF")
  })

  testSync("starts an interval one interval after it is set", () => {
    let i = input(Every(Minutes(5)))
    expect(i.scheduleExpression)->toBe("rate(5 minutes)")
    expect(i.startDate->Option.map(Date.getTime))->toEqual(Some(setAt +. 5. *. 60_000.))
    expect(i.actionAfterCompletion)->toEqual(Some("NONE"))
  })

  testSync("deletes a once-only schedule after it fires, read in its zone", () => {
    let i = input(Once({moment: After(Minutes(10)), zone: "Europe/Berlin"}))
    expect(i.scheduleExpression)->toBe("at(2026-10-15T16:12:00)")
    expect(i.scheduleExpressionTimezone)->toEqual(Some("Europe/Berlin"))
    expect(i.actionAfterCompletion)->toEqual(Some("DELETE"))
  })

  testSync("gives a FIFO queue a message group, a standard queue none", () => {
    let fifo = input(~targetArn=fifoArn, Every(Hours(1)))
    expect(fifo.target.sqsParameters->Option.flatMap(p => p.messageGroupId))->toEqual(
      Some("disconnect-p1"),
    )
    expect(input(Every(Hours(1))).target.sqsParameters)->toEqual(None)
  })

  testSync("grants the schedules of the role's group, or of every group in the account", () => {
    expect(roleArn->Runtime.schedulesOfRoleArn)->toBe(
      "arn:aws:scheduler:*:123456789012:schedule/SchedulerRole-1a2b3c4/*",
    )
    expect("123456789012"->Runtime.schedulesOfAccount)->toBe(
      "arn:aws:scheduler:*:123456789012:schedule/SchedulerRole-*/*",
    )
  })

  testSync("a schedule group's tags carry no empty value, which AWS refuses", () => {
    let tags = Dict.fromArray([("Name", "SchedulerScheduleGroup"), ("reventless:plugin", "")])
    expect(tags->AWS.Tags.withoutEmpty->Dict.toArray)->toEqual([("Name", "SchedulerScheduleGroup")])
  })

  testSync("names an automation's schedule <slice>.<key>, or hashes a key it would refuse", () => {
    expect(Runtime.tickScheduleName(~slice="MarketingDigest", ~key="r1"))->toBe(
      "MarketingDigest.r1",
    )
    let hashed = Runtime.tickScheduleName(~slice="MarketingDigest", ~key="customer:42")
    expect((hashed->String.startsWith("MarketingDigest."), hashed->String.length))->toEqual((
      true,
      16 + 16,
    ))
    let long = "A"->String.repeat(60)
    let cut = Runtime.tickScheduleName(~slice=long, ~key="default")
    expect((cut->String.length, cut->Runtime.isSliceSchedule(~slice=long)))->toEqual((57, true))
  })

  testSync("tells a slice's schedules from another slice's sharing its prefix", () => {
    expect("Digest.r1"->Runtime.isSliceSchedule(~slice="Digest"))->toBe(true)
    expect("DigestWeekly.r1"->Runtime.isSliceSchedule(~slice="Digest"))->toBe(false)
  })

  testSync("invokes the automation Lambda with the slice, the key and the scheduled time", () => {
    expect(
      Runtime.tickInput(~slice="MarketingDigest", ~key="r1"),
    )->toBe(`{"reventlessTick":{"slice":"MarketingDigest","key":"r1","at":"<aws.scheduler.scheduled-time>"}}`)
  })
})
