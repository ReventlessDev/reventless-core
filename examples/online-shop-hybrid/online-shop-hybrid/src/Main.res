module Platform = ReventlessInMemory.Platform.Make()

module Catalog = CatalogPlugin.CatalogPlugin.Make(Platform)
module Ordering = OrderingPlugin.OrderingPlugin.Make(Platform)

Platform.makePlatform(
  ~version="1.0.0",
  ~plugins=[module(Catalog), module(Ordering)],
)
