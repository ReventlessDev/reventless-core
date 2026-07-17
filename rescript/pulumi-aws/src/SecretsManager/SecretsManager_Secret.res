/** @pulumi/aws/secretsmanager/secret
  see: https://www.pulumi.com/registry/packages/aws/api-docs/secretsmanager/secret
*/
type t = {
  arn: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
}

type args = {
  name?: Pulumi.Input.t<string>,
  namePrefix?: Pulumi.Input.t<string>,
  description?: Pulumi.Input.t<string>,
  kmsKeyId?: Pulumi.Input.t<string>,
  /** Days before a deleted secret is irrecoverably purged. Set `0` to delete
    immediately (handy for throwaway CI/dev stacks). */
  recoveryWindowInDays?: Pulumi.Input.t<int>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("secretsmanager") @new
external make: (~name: string, ~args: args=?, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "Secret"
