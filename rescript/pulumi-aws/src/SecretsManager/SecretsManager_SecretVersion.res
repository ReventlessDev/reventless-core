/** @pulumi/aws/secretsmanager/secretversion
  see: https://www.pulumi.com/registry/packages/aws/api-docs/secretsmanager/secretversion
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  versionId: Pulumi.Output.t<string>,
}

type args = {
  secretId: Pulumi.Input.t<string>,
  /** Plaintext secret payload (typically a JSON connection blob). Prefer
    `secretString` over `secretBinary`. */
  secretString?: Pulumi.Input.t<string>,
  secretBinary?: Pulumi.Input.t<string>,
  versionStages?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
}

@module("@pulumi/aws") @scope("secretsmanager") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "SecretVersion"
