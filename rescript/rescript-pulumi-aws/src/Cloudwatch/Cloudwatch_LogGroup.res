/** @pulumi/aws/cloudwatch/loggroup
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudwatch/loggroup/
*/
type t = {name: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>, id: Pulumi.Output.t<string>}

type args = {
  name?: Pulumi.Input.t<string>,
  retentionInDays?: Pulumi.Input.t<int>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("cloudwatch") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "LogGroup"
