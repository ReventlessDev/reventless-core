/** @pulumi/pulumi/asset
  see: https://www.pulumi.com/docs/reference/pkg/nodejs/pulumi/pulumi/asset
*/
type t

type assetOrArchive

external assetToAssetOrArchive: Asset.t => assetOrArchive = "%identity"
external archiveToAssetOrArchive: t => assetOrArchive = "%identity"

@module("@pulumi/pulumi") @scope("asset") @new
external assetArchive: dict<assetOrArchive> => t = "AssetArchive"

@module("@pulumi/pulumi") @scope("asset") @new
external fileArchive: string => t = "FileArchive"

@module("@pulumi/pulumi") @scope("asset") @new
external remoteArchive: string => t = "RemoteArchive"
