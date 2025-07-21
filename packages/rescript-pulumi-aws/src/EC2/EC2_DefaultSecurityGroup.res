/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/defaultsecuritygroup
*/
type t

type args = {vpcId: string, tags?: Aws.tags}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "DefaultSecurityGroup"

let make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args=?,
  ~opts=?,
) => {
  let args = args->Option.map(args => {
    vpcId: args.vpcId,
    tags: args.tags->EC2_Common.supplementTagsWithName(name),
  })
  make(~name, ~args?, ~opts?)
}
