/** @pulumi/aws/s3/BucketOwnershipControls
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketownershipcontrols
*/
open Pulumi

type t

type objectOwnership = BucketOwnerEnforced | BucketOwnerPreferred | ObjectWriter

type rule = {objectOwnership: objectOwnership}

type args = {
  bucket: Input.t<string> /* bucket.id */,
  rule: rule,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t =
  "BucketOwnershipControls"
