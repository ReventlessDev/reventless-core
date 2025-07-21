/** @pulumi/aws/s3/BucketPublicAccessBlock
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketpublicaccessblock
*/
type t

type args = {
  bucket: Pulumi.Input.t<string> /* bucket.id */,
  blockPublicAcls: Pulumi.Input.t<bool>,
  blockPublicPolicy: Pulumi.Input.t<bool>,
  ignorePublicAcls: Pulumi.Input.t<bool>,
  restrictPublicBuckets: Pulumi.Input.t<bool>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "BucketPublicAccessBlock"
