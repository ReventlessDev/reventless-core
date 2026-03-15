// Catalog DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, StateViewSlices, the
// ProductsExtensionPoint (outbound), and the OrdersExtension (inbound).

module Make = (Platform: ReventlessInfra.Platform.T) => {
  module CatalogEventLogMaker = Platform.DcbEventLog.Make(CatalogEventLog)

  module AddProductSlice = Platform.StateChangeSlice.Make(AddProduct)
  module ChangeProductNameSlice = Platform.StateChangeSlice.Make(ChangeProductName)
  module ChangeProductDescriptionSlice = Platform.StateChangeSlice.Make(ChangeProductDescription)
  module ChangeProductPriceSlice = Platform.StateChangeSlice.Make(ChangeProductPrice)

  module ProductsViewSlice = Platform.StateViewSlice.Make(ProductsView)

  module AddCategorySlice = Platform.StateChangeSlice.Make(AddCategory)
  module RenameCategorySlice = Platform.StateChangeSlice.Make(RenameCategory)
  module ArchiveCategorySlice = Platform.StateChangeSlice.Make(ArchiveCategory)

  module CategoriesViewSlice = Platform.StateViewSlice.Make(CategoriesView)

  module ImportProductSlice = Platform.InboundTranslationSlice.Make(ImportProduct)

  // Demand tracking — driven by Ordering's OrdersExtensionPoint
  module RecordProductDemandSlice = Platform.StateChangeSlice.Make(RecordProductDemand)
  module ProductDemandViewSlice = Platform.StateViewSlice.Make(ProductDemandView)

  // Compile the Products extension point mapping, then build the EP component
  module ProductsEPMappingT = ReventlessInfra.ExtensionPointMapping.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsExtensionPointMapping,
  )
  module ProductsEPMappings = {
    module Spec = CatalogSpec.ProductsExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionPointMapping.T with module ExtensionPoint := Spec
    let mappings: array<module(Mapping)> = [module(ProductsEPMappingT)]
  }
  module ProductsExtensionPointMaker = Platform.ExtensionPoint.Make(
    CatalogSpec.ProductsExtensionPoint,
    ProductsEPMappings,
  )

  // Build the Orders extension (subscribing to Ordering's EP)
  module OrdersDemandMapping = ReventlessInfra.ExtensionMapping.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtension.DemandMapping,
  )
  module OrdersExtensionMappings = {
    module Spec = OrderingSpec.OrdersExtensionPoint
    module type Mapping = ReventlessInfra.ExtensionMapping.T
      with module ExtensionPoint := Spec
    let name = "CatalogDemand"
    let mappings: array<module(Mapping)> = [module(OrdersDemandMapping)]
  }
  module OrdersExtensionMaker = Platform.Extension.Make(
    OrderingSpec.OrdersExtensionPoint,
    OrdersExtensionMappings,
  )

  // --- Self-assembly: produce a ready-to-use Plugin.component ---

  module DcbSpec = {
    @schema
    type event = CatalogEventLog.event
    let stateChangeSlices: array<
      module(ReventlessInfra.StateChangeSlice.T with type dcbEvent = event),
    > = [
      module(AddProductSlice),
      module(ChangeProductNameSlice),
      module(ChangeProductDescriptionSlice),
      module(ChangeProductPriceSlice),
      module(AddCategorySlice),
      module(RenameCategorySlice),
      module(ArchiveCategorySlice),
      module(RecordProductDemandSlice),
    ]
    let stateViewSlices: array<
      module(ReventlessInfra.StateViewSlice.T with type dcbEvent = event),
    > = [
      module(ProductsViewSlice),
      module(CategoriesViewSlice),
      module(ProductDemandViewSlice),
    ]
    let automationSlices: array<
      module(ReventlessInfra.AutomationSlice.T with type dcbEvent = event),
    > = []
    let outboundTranslationSlices: array<
      module(ReventlessInfra.OutboundTranslationSlice.T with type dcbEvent = event),
    > = []
    let inboundTranslationSlices: array<
      module(ReventlessInfra.InboundTranslationSlice.T with type dcbEvent = event),
    > = [module(ImportProductSlice)]
  }

  let make = (
    ~scheduler: Pulumi.Output.t<ReventlessInfra.Scheduler.operations>,
    ~api: Platform.api,
    ~apiRole: Platform.role,
  ) =>
    Platform.Plugin.make(
      ~name="Catalog",
      ~heartbeatInterval=60,
      ~extensionPoints=[module(ProductsExtensionPointMaker)],
      ~extensions=[module(OrdersExtensionMaker)],
      ~api,
      ~apiRole,
      ~scheduler,
      ~dcbSpec=module(DcbSpec),
    )
}
