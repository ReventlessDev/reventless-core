/** @pulumi/aws/s3/BucketObject
  see: https://www.pulumi.com/registry/packages/aws/api-docs/s3/bucketobject
*/
type t = {
  id: Pulumi.Output.t<string>,
  key: Pulumi.Output.t<string>,
  etag: Pulumi.Output.t<string>,
}

type args = {
  bucket: Pulumi.Input.t<string>,
  key: Pulumi.Input.t<string>,
  source?: Pulumi.Input.t<Pulumi.Asset.t>,
  content?: Pulumi.Input.t<string>,
  contentType?: Pulumi.Input.t<string>,
  cacheControl?: Pulumi.Input.t<string>,
  etag?: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("s3") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "BucketObject"
