/** @pulumi/aws/s3/BucketV2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketv2
*/
@module("@pulumi/aws")
@scope("s3")
@new
external make: (
  ~name: string,
  ~args: S3_Bucket.args=?,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => S3_Bucket.t = "BucketV2"
