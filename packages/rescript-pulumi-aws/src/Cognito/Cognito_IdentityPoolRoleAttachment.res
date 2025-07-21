/** @pulumi/aws/cognito/IdentityPoolRoleAttachment
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cognito/identitypoolroleattachment
*/
type t

type roles = {
  authenticated?: Pulumi.Input.t<string>,
  unauthenticated?: Pulumi.Input.t<string>,
}

type args = {
  identityPoolId?: Pulumi.Input.t<string>,
  roles: Pulumi.Input.t<roles>,
}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "IdentityPoolRoleAttachment"
