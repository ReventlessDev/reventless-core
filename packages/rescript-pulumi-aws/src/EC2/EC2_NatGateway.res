/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/natgateway
*/
type t = {id: Pulumi.Output.t<string>}

type args = {
  allocationId: Pulumi.Input.t<string>,
  subnetId: Pulumi.Input.t<string>,
  tags?: Aws.tags,
}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "NatGateway"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      allocationId: args.allocationId,
      subnetId: args.subnetId,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    },
    ~opts?,
  )
}
