/** @pulumi/aws/ec2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/ec2/vpcendpoint
*/
type t = {id: Pulumi.Output.t<string>}

type vpcEndpointType = Gateway | GatewayLoadBalancer | Interface

type args = {
  policy?: Pulumi.Input.t<string>,
  privateDnsEnabled?: bool,
  /** routeTableIds are only relevant if endpointType = Gateway */
  routeTableIds?: array<Pulumi.Input.t<string>>,
  securityGroupIds?: array<Pulumi.Input.t<string>>,
  /** Subnets the Interface endpoint's ENIs are placed in (one per AZ). Required
    for `Interface` endpoints; ignored for `Gateway`. */
  subnetIds?: array<Pulumi.Input.t<string>>,
  serviceName: Pulumi.Input.t<string>,
  tags?: Aws.tags,
  /** Default: Gateway */
  vpcEndpointType?: vpcEndpointType,
  vpcId: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("ec2") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "VpcEndpoint"

let make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = (
  ~name,
  ~args,
  ~opts=?,
) => {
  make(
    ~name,
    ~args={
      policy: ?args.policy,
      privateDnsEnabled: ?args.privateDnsEnabled,
      securityGroupIds: ?args.securityGroupIds,
      subnetIds: ?args.subnetIds,
      serviceName: args.serviceName,
      tags: args.tags->EC2_Common.supplementTagsWithName(name),
      vpcEndpointType: ?args.vpcEndpointType,
      vpcId: args.vpcId,
    },
    ~opts?,
  )
}
