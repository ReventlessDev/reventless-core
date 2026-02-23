/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/eip
*/
type t = {id: Pulumi.Output.t<string>}

type args = {vpc: bool, tags?: Aws.tags}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Eip"

let make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args=?,
  ~opts=?,
) => {
  make(
    ~name,
    ~args=?args->Option.map(args => {
      vpc: args.vpc,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    }),
    ~opts?,
  )
}
