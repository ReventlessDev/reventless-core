/** @pulumi/aws/rds/subnetgroup
  see: https://www.pulumi.com/registry/packages/aws/api-docs/rds/subnetgroup
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type args = {
  name?: Pulumi.Input.t<string>,
  subnetIds: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("rds") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "SubnetGroup"
