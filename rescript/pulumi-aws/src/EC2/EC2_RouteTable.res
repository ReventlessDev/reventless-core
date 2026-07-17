/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/routetable
*/
module Route = {
  type t

  type transparent = {
    cidrBlock: string,
    gatewayId?: Pulumi.Input.t<string>,
    natGatewayId?: Pulumi.Input.t<string>,
  }
  external toTransparent: t => transparent = "%identity"
  %%private(external make: transparent => t = "%identity")
  let makeInternetGatewayRoute = (~cidrBlock: string, ~gatewayId: Pulumi.Input.t<string>) =>
    {
      cidrBlock,
      gatewayId,
    }->make

  let makeNatGatewayRoute = (~cidrBlock: string, ~natGatewayId: Pulumi.Input.t<string>) =>
    {
      cidrBlock,
      natGatewayId,
    }->make
}

type args = {vpcId: Pulumi.Input.t<string>, routes: array<Route.t>, tags?: Aws.tags}

type t = {id: Pulumi.Output.t<string>}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "RouteTable"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      vpcId: args.vpcId,
      routes: args.routes,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
    },
    ~opts?,
  )
}
