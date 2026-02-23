/** @pulumi/aws/cognito/UserPoolClient
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cognito/userpoolclient
*/
open Pulumi

type t = {
  urn: Output.t<string>,
  name: Output.t<string>,
  id: Output.t<string>,
  userPoolId: Output.t<string>,
}

type args = {userPoolId: Input.t<string>, name?: Input.t<string>}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t =
  "UserPoolClient"
