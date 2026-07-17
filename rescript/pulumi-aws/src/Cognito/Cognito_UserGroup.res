/** @pulumi/aws/cognito/UserGroup
   see: https://www.pulumi.com/registry/packages/aws/api-docs/cognito/usergroup
 */
type t

type args = {
  description?: Pulumi.Input.t<string>,
  name?: Pulumi.Input.t<string>,
  precedence?: Pulumi.Input.t<string>,
  roleArn?: Pulumi.Input.t<string>,
  userPoolId: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "UserGroup"
