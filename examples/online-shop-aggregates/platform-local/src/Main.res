module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

@val external processEnv: dict<string> = "process.env"

module CatalogMaker = {
  let make = () =>
    Catalog.make(~uiBundleUrl=?processEnv->Dict.get("CATALOG_UI_BUNDLE_URL"))
}
module OrderingMaker = {
  let make = () =>
    Ordering.make(~uiBundleUrl=?processEnv->Dict.get("ORDERING_UI_BUNDLE_URL"))
}

Platform.makePlatform(
  ~version=Reventless.PackageVersion.fromCwd(),
  ~plugins=[module(CatalogMaker), module(OrderingMaker)],
)

Platform.startServers()
