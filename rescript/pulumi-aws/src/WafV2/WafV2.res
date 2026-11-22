/** @pulumi/aws/wafv2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/wafv2

  A web ACL and its association with a regional resource (an AppSync API, a load
  balancer). The rule statements are deeply nested and mostly constant, so they
  are given as JSON; only what a deployment computes is an input.
*/
module WebAcl = {
  type t = {id: Pulumi.Output.t<string>, arn: Pulumi.Output.t<string>}

  type args = {
    /** `REGIONAL` for an AppSync API. */
    scope: string,
    description?: string,
    /** `{"allow": {}}` or `{"block": {}}`. */
    defaultAction: JSON.t,
    rules: Pulumi.Input.t<array<JSON.t>>,
    visibilityConfig: JSON.t,
    tags?: Pulumi.Input.t<Aws.tags>,
  }

  @module("@pulumi/aws") @scope("wafv2") @new
  external make: (
    ~name: string,
    ~args: args,
    ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  ) => t = "WebAcl"
}

module WebAclAssociation = {
  type t = {id: Pulumi.Output.t<string>}

  type args = {
    resourceArn: Pulumi.Input.t<string>,
    webAclArn: Pulumi.Input.t<string>,
  }

  @module("@pulumi/aws") @scope("wafv2") @new
  external make: (
    ~name: string,
    ~args: args,
    ~opts: option<Pulumi.CustomResourceOptions.t>=?,
  ) => t = "WebAclAssociation"
}
