/** @pulumi/aws/kms/key
  see: https://www.pulumi.com/registry/packages/aws/api-docs/kms/key
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  keyId: Pulumi.Output.t<string>,
}

type args = {
  description?: Pulumi.Input.t<string>,
  /** Days a scheduled deletion waits, 7 to 30. */
  deletionWindowInDays?: Pulumi.Input.t<int>,
  enableKeyRotation?: Pulumi.Input.t<bool>,
  /** `ENCRYPT_DECRYPT` (the default) for a symmetric key. */
  keyUsage?: Pulumi.Input.t<string>,
  /** A JSON key policy; absent, the account's default policy applies. */
  policy?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("kms") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Key"
