/** @pulumi/aws/ecs/cluster
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ecs/cluster/
*/
type t = {arn: Pulumi.Output.t<string>, id: Pulumi.Output.t<string>}

type args = {name?: Pulumi.Input.t<string>}

@module("@pulumi/aws") @scope("ecs") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Cluster"
