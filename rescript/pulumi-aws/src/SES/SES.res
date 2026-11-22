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

/** @pulumi/aws/sesv2/ConfigurationSet: what a send names to be handled a set way,
    here so that addresses which bounced or complained are kept off the list. */
module ConfigurationSet = {
  type t = {
    arn: Pulumi.Output.t<string>,
    configurationSetName: Pulumi.Output.t<string>,
  }

  /** `["BOUNCE", "COMPLAINT"]`. */
  type suppressionOptions = {suppressedReasons: array<string>}

  type args = {
    configurationSetName: string,
    suppressionOptions?: suppressionOptions,
    tags?: Pulumi.Input.t<PulumiAws.Aws.tags>,
  }

  @module("@pulumi/aws") @new @scope("sesv2")
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "ConfigurationSet"
}
