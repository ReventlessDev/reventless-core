/** @pulumi/aws/kms/alias
  see: https://www.pulumi.com/registry/packages/aws/api-docs/kms/alias
*/
type t = {
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type args = {
  /** Must start with `alias/`. */
  name?: Pulumi.Input.t<string>,
  targetKeyId: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("kms") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Alias"
