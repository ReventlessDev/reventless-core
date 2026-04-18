/** @pulumi/aws/s3/BucketPolicy
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketpolicy
*/
type t

type args = {
  bucket: Pulumi.Input.t<string>,
  policy: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "BucketPolicy"
