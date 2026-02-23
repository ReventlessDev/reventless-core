/** @pulumi/aws/s3/BucketAclV2
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketaclv2
*/
open Pulumi

type t

type acl =
  | @as("private") Private
  | @as("public-read") PublicRead
  | @as("public-read-write") PublicReadWrite
  | @as("aws-exec-read") AwsExecRead
  | @as("authenticated-read") AuthenticatedRead
  | @as("bucket-owner-read") BucketOwnerRead
  | @as("bucket-owner-full-control") BucketOwnerFullControl
  | @as("log-delivery-write") LogDeliveryWrite

type args = {
  bucket: Input.t<string> /* bucket.id */,
  acl: Input.t<acl>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t = "BucketAclV2"
