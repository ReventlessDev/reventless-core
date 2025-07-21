/** @pulumi/aws/secretsmanager/getsecretversion
  see: https://www.pulumi.com/registry/packages/aws/api-docs/secretsmanager/getsecretversion
*/
type args = {
  secretId: string,
  versionId?: string,
  versionStage?: string,
}

type t = {
  arn: string,
  id: string,
  secretId: string,
  secretBinary: string,
  secretString: string,
  versionId: string,
  versionStage: option<string>,
  versionStages: array<string>,
}

@module("@pulumi/aws") @scope("secretsmanager") @val
external getSecretVersionOutput: (
  ~args: args=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => Pulumi.Output.t<t> = "getSecretVersionOutput"

let decodeSecret = secret =>
  secret.secretString
  ->Js.Json.parseExn
  ->Js.Json.decodeObject
  ->Option.getOr(Js.Dict.empty())
  ->(Js.Dict.map(json => json->Js.Json.decodeString->Option.getOr(""), _))

let getSecretNames = arn =>
  getSecretVersionOutput(~args={secretId: arn})->Pulumi.Output.apply(secret =>
    secret->decodeSecret->Js.Dict.keys
  )
