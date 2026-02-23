// CatalogItem plugin — platform-agnostic composition root.
// Wire the aggregate and read model together using any Platform implementation.

module Make = (Platform: ReventlessSpec.Platform.T) => {
  module ItemAggregate = Platform.Aggregate.Make(
    CatalogItem,
    CatalogItemBehavior,
    Reventless.NoEventMappings.Make(CatalogItem),
  )

  module MappingsHelper = Reventless.Projection.Mappings.Make(CatalogItemsReadModel)

  module Mappings: ReventlessSpec.Projection.Mappings
    with module Target := CatalogItemsReadModel = {
    module type Mapping = MappingsHelper.Mapping
    let mappings = CatalogItemsProjections.mappings
  }

  module ItemReadModel = Platform.ReadModel.Make(CatalogItemsReadModel, Mappings)
}
