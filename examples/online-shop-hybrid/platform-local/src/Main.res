module Platform = ReventlessLocal.Platform.Make()

module Catalog = CatalogPlugin.Plugin.Make(Platform)
module Ordering = OrderingPlugin.Plugin.Make(Platform)

// Plugin UI bundle URLs are deployment config supplied by the platform, not
// the plugin package. Each platform deployment picks the URL that serves its
// plugins' UI bundles: local dev servers here, CloudFront outputs in AWS.
// Unset env → plugin reports no uiFragments; no runtime UI registration.
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
