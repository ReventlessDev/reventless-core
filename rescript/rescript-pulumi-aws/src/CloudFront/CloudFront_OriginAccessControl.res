/** @pulumi/aws/cloudfront/OriginAccessControl
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cloudfront/originaccesscontrol
*/
type t = {
  id: Pulumi.Output.t<string>,
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type args = {
  name?: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  originAccessControlOriginType: Pulumi.Input.t<string>,
  signingBehavior: Pulumi.Input.t<string>,
  signingProtocol: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("cloudfront") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "OriginAccessControl"
