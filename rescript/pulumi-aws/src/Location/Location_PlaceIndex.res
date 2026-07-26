/** @pulumi/aws/location/PlaceIndex
  see: https://www.pulumi.com/registry/packages/aws/api-docs/location/placeindex/
*/
type dataSourceConfiguration = {
  // "SingleUse" | "Storage" — geocoding for immediate display uses SingleUse.
  intendedUse?: Pulumi.Input.t<string>,
}

type args = {
  indexName: Pulumi.Input.t<string>,
  // Provider of geospatial data: "Esri" | "Grab" | "Here".
  dataSource: Pulumi.Input.t<string>,
  dataSourceConfiguration?: Pulumi.Input.t<dataSourceConfiguration>,
  description?: Pulumi.Input.t<string>,
  tags?: Pulumi.Input.t<Aws.tags>,
}

type t = {
  indexName: Pulumi.Output.t<string>,
  indexArn: Pulumi.Output.t<string>,
  createTime: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("location") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "PlaceIndex"

@module("@pulumi/aws") @scope(("location", "PlaceIndex"))
external get: (
  ~name: string,
  ~id: Pulumi.Input.t<string>,
  ~opts: Pulumi.CustomResourceOptions.t=?,
) => t = "get"
