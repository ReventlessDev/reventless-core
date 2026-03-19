/** @pulumi/pulumi/asset
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/asset
*/
type t

@module("@pulumi/pulumi") @scope("asset") @new
external fileAsset: string => t = "FileAsset"

@module("@pulumi/pulumi") @scope("asset") @new
external stringAsset: string => t = "StringAsset"

@module("@pulumi/pulumi") @scope("asset") @new
external remoteAsset: string => t = "RemoteAsset"
