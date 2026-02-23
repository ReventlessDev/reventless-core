// CatalogItem plugin — platform-agnostic composition root.
// Wire the aggregate and read model together using any Platform implementation.

module Make = (Platform: ReventlessSpec.Platform.T) => {
  module ItemAggregate = Platform.Aggregate.Make(
    CatalogItemSpec,
    CatalogItemBehavior,
    Reventless.NoEventMappings.Make(CatalogItemSpec),
  )

  module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemReadModelSpec)

  module Mappings: ReventlessSpec.Projection.Mappings with module Target := CatalogItemReadModelSpec = {
    module type Mapping = MappingsHelper.Mapping
    let mappings = CatalogItemProjection.mappings
  }

  module ItemReadModel = Platform.ReadModel.Make(CatalogItemReadModelSpec, Mappings)
}
