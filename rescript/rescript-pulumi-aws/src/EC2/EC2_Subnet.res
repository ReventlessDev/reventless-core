/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/subnet
*/
type t = {id: Pulumi.Output.t<string>}

type args = {
  cidrBlock: string,
  vpcId: Pulumi.Input.t<string>,
  availabilityZone?: Aws.AvailabilityZone.t,
  tags?: Aws.tags,
}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Subnet"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      cidrBlock: args.cidrBlock,
      vpcId: args.vpcId,
      availabilityZone: ?args.availabilityZone,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    },
    ~opts?,
  )
}
