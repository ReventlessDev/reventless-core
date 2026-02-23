module EmailIdentity = {
  type t = {
    arn: Pulumi.Output.t<Aws.arn>,
    email: Pulumi.Output.t<string>,
  }

  type args = {email: string}

  @module("@pulumi/aws") @new @scope("ses")
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "EmailIdentity"
}

module IdentityPolicy = {
  type t

  type args = {
    identity: Pulumi.Input.t<PulumiAws.Aws.arn>,
    policy: Pulumi.Input.t<string>,
  }

  @module("@pulumi/aws") @new @scope("ses")
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "IdentityPolicy"
}
