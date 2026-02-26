// Catalog plugin — platform-agnostic composition root.
// Wires the Product and Category aggregates and their read models.

open Reventless
open Reventless.Projection

module Make = (Platform: Platform.T) => {
  module ProductAggregate = Platform.Aggregate.Make(
    Product,
    ProductBehavior,
    NoEventMappings.Make(Product),
  )

  module CategoryAggregate = Platform.Aggregate.Make(
    Category,
    CategoryBehavior,
    NoEventMappings.Make(Category),
  )

  module ProductMappings: Mappings with module Target := ProductsReadModel = {
    module ProductMappings = Mappings.Make(ProductsReadModel)
    module type Mapping = ProductMappings.Mapping
    let mappings = ProductsProjections.mappings
  }

  module ProductReadModel = Platform.ReadModel.Make(ProductsReadModel, ProductMappings)

  module CategoryMappings: Mappings with module Target := CategoriesReadModel = {
    module CategoryMappings = Mappings.Make(CategoriesReadModel)
    module type Mapping = CategoryMappings.Mapping
    let mappings = CategoriesProjections.mappings
  }

  module CategoryReadModel = Platform.ReadModel.Make(CategoriesReadModel, CategoryMappings)
}
