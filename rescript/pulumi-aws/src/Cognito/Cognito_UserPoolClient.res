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

type tokenValidityUnits = {
  accessToken?: Input.t<string>,
  idToken?: Input.t<string>,
  refreshToken?: Input.t<string>,
}

type args = {
  userPoolId: Input.t<string>,
  name?: Input.t<string>,
  generateSecret?: Input.t<bool>,
  explicitAuthFlows?: Input.t<array<Input.t<string>>>,
  preventUserExistenceErrors?: Input.t<string>,
  idTokenValidity?: Input.t<int>,
  accessTokenValidity?: Input.t<int>,
  refreshTokenValidity?: Input.t<int>,
  tokenValidityUnits?: Input.t<tokenValidityUnits>,
}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t =
  "UserPoolClient"
