/** @pulumi/aws/cloudwatch/eventrule
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudwatch/eventrule/
*/
type t = {name: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>, id: Pulumi.Output.t<string>}

module ScheduleExpression: {
  type t
  type rate =
    | Minutes(int)
    | Hours(int)
    | Days(int)

  let every: rate => t
  let rate: rate => t
} = {
  /** Either a cron or rate expression
      * see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/ScheduledEvents.html
    */
  type t = Pulumi.Input.t<string>

  type rate =
    | Minutes(int)
    | Hours(int)
    | Days(int)

  let plural = count => count == 1 ? "" : "s"

  let every = rate =>
    switch rate {
    | Minutes(minutes) =>
      let plural = minutes->plural
      `rate(${minutes->Int.toString} minute${plural})`
    | Hours(hours) =>
      let plural = hours->plural
      `rate(${hours->Int.toString} hour${plural})`
    | Days(days) =>
      let plural = days->plural
      `rate(${days->Int.toString} day${plural})`
    }->Pulumi.Input.make

  let rate = every
}

type args = {
  description?: Pulumi.Input.t<string>,
  scheduleExpression?: ScheduleExpression.t,
  roleArn?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "EventRule"
