/** @pulumi/aws/scheduler/schedulegroup
  see: https://www.pulumi.com/registry/packages/aws/api-docs/scheduler/schedulegroup/
*/
type t = {name: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>, id: Pulumi.Output.t<string>}

type args = {
  /** 1 to 64 characters from letters, digits, `-`, `_` and `.`; generated when absent. */
  name?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("scheduler") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "ScheduleGroup"
