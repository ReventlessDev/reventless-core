/**ocaml.doc(" @pulumi/aws/sqsqueuepolicy
  see: https://www.pulumi.com/registry/packages/aws/api-docs/sqs/queuepolicy
*/
type args = {
  policy: Pulumi.Input.t<string>,
  queueUrl: Pulumi.Input.t<string>,
}

type t = {id: Pulumi.Output.t<string>}

@module("@pulumi/aws") @scope("sqs") @new
external make: (~name: string, ~args: args, ~opts: option<Pulumi.CustomResourceOptions.t>) => t =
  "QueuePolicy"
