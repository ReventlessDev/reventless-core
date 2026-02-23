/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/securitygroup
*/
type t = {id: Pulumi.Output.t<string>}

module Ingress = {
  type t = {fromPort: int, protocol: string, toPort: int, cidrBlocks: array<string>}
  let allowAll = {fromPort: 0, protocol: "-1", toPort: 0, cidrBlocks: ["0.0.0.0/0"]}
}

module Egress = {
  type t = {fromPort: int, protocol: string, toPort: int, cidrBlocks: array<string>}
  let allowAll = {fromPort: 0, protocol: "-1", toPort: 0, cidrBlocks: ["0.0.0.0/0"]}
}

type args = {
  name: string,
  vpcId: Pulumi.Input.t<string>,
  ingress: array<Ingress.t>,
  egress: array<Egress.t>,
  tags?: Aws.tags,
}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "SecurityGroup"

let make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args=?,
  ~opts=?,
) => {
  make(
    ~name,
    ~args=?args->Option.map(args => {
      name: args.name,
      vpcId: args.vpcId,
      ingress: args.ingress,
      egress: args.egress,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    }),
    ~opts?,
  )
}
