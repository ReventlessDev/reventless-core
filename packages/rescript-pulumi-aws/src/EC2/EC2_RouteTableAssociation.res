/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/routetableassociation
*/
type t

type args = {
  routeTableId: Pulumi.Input.t<string>,
  subnetId: Pulumi.Input.t<string>,
  tags?: Aws.tags,
}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "RouteTableAssociation"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      routeTableId: args.routeTableId,
      subnetId: args.subnetId,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    },
    ~opts?,
  )
}
