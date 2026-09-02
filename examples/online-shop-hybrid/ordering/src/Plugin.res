// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

@val external uiBundleUrl: option<string> = "process.env.ORDERING_UI_BUNDLE_URL"

let dcbSliceSchemas: array<Reventless.DcbTag.sliceSchemas> = [
  {name: CancelOrder.name, commandSchema: CancelOrder.commandSchema->S.castToUnknown, consumedEventSchema: CancelOrder.consumedEventSchema->S.castToUnknown, eventSchema: CancelOrder.eventSchema->S.castToUnknown},
  {name: NotificationPreferences.name, commandSchema: NotificationPreferences.commandSchema->S.castToUnknown, consumedEventSchema: NotificationPreferences.consumedEventSchema->S.castToUnknown, eventSchema: NotificationPreferences.eventSchema->S.castToUnknown},
  {name: NotificationSourceClaims.name, commandSchema: NotificationSourceClaims.commandSchema->S.castToUnknown, consumedEventSchema: NotificationSourceClaims.consumedEventSchema->S.castToUnknown, eventSchema: NotificationSourceClaims.eventSchema->S.castToUnknown},
  {name: PlaceOrder.name, commandSchema: PlaceOrder.commandSchema->S.castToUnknown, consumedEventSchema: PlaceOrder.consumedEventSchema->S.castToUnknown, eventSchema: PlaceOrder.eventSchema->S.castToUnknown},
  {name: ShipOrder.name, commandSchema: ShipOrder.commandSchema->S.castToUnknown, consumedEventSchema: ShipOrder.consumedEventSchema->S.castToUnknown, eventSchema: ShipOrder.eventSchema->S.castToUnknown},
  {name: SyncCatalogProduct.name, commandSchema: SyncCatalogProduct.commandSchema->S.castToUnknown, consumedEventSchema: SyncCatalogProduct.consumedEventSchema->S.castToUnknown, eventSchema: SyncCatalogProduct.eventSchema->S.castToUnknown},
]

module Make = (Platform: ReventlessInfra.Platform.T) => {
  // StateChangeSlices
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder, CancelOrder_Behavior)
  module NotificationPreferencesSlice = Platform.StateChangeSlice.Make(NotificationPreferences, NotificationPreferences_Behavior)
  module NotificationSourceClaimsSlice = Platform.StateChangeSlice.Make(NotificationSourceClaims, NotificationSourceClaims_Behavior)
  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder, PlaceOrder_Behavior)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder, ShipOrder_Behavior)
  module SyncCatalogProductSlice = Platform.StateChangeSlice.Make(SyncCatalogProduct, SyncCatalogProduct_Behavior)

  // StateViewSliceStreams
  module AvailableProductsStreamSlice = Platform.StateViewSliceStream.Make(AvailableProducts, AvailableProducts_Projection)
  module NotificationDeliveriesStreamSlice = Platform.StateViewSliceStream.Make(NotificationDeliveries, NotificationDeliveries_Projection)
  module NotificationSubscriptionsStreamSlice = Platform.StateViewSliceStream.Make(NotificationSubscriptions, NotificationSubscriptions_Projection)
  module OrdersStreamSlice = Platform.StateViewSliceStream.Make(Orders, Orders_Projection)

  // AutomationSlices
  module AutoShipOrderSlice = Platform.AutomationSlice.Make(AutoShipOrder, AutoShipOrder_Automation)
  module NotificationIntakeSlice = Platform.AutomationSlice.Make(NotificationIntake, NotificationIntake_Automation)

  // OutboundTranslationSlices
  module AnnounceRecipientContactSlice = Platform.OutboundTranslationSlice.Make(AnnounceRecipientContact, AnnounceRecipientContact_Translation)
  module GeocodeCustomerAddressSlice = Platform.OutboundTranslationSlice.Make(GeocodeCustomerAddress, GeocodeCustomerAddress_Translation)
  module SendNotificationSlice = Platform.OutboundTranslationSlice.Make(SendNotification, SendNotification_Translation)

  // Aggregates
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    Customer_Behavior,
    ReventlessInfra.NoEventMappings.Make(Customer),
  )

  // ReadModels
  module CustomersReadModel = Platform.ReadModelStream.Make(Customers, Customers_Projections)

  // ExtensionPoints
  module Orders_ExtensionPoint = Platform.ExtensionPoint.Make(Orders_ExtensionPointMapping)

  // Extensions
  module Products_Extension = Platform.Extension.Make(Products_Extension.Mapping)

  let pluginStructure = Platform.Plugin.makePluginDefinition(
    ~name="Ordering",
    ~aggregates=[module(CustomerAggregate)],
    ~readModels=[module(CustomersReadModel)],
    ~stateViewSlices=[module(AvailableProductsStreamSlice), module(NotificationDeliveriesStreamSlice), module(NotificationSubscriptionsStreamSlice), module(OrdersStreamSlice)],
    ~stateChangeSlices=[module(CancelOrderSlice), module(NotificationPreferencesSlice), module(NotificationSourceClaimsSlice), module(PlaceOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
    ~automationSlices=[module(AutoShipOrderSlice), module(NotificationIntakeSlice)],
    ~outboundTranslationSlices=[module(AnnounceRecipientContactSlice), module(GeocodeCustomerAddressSlice), module(SendNotificationSlice)],
    ~extensions=[module(Products_Extension)],
    ~extensionPoints=[module(Orders_ExtensionPointMapping)],
    ~componentChapters=Dict.fromArray([("AnnounceRecipientContact", "Notification"), ("AutoShipOrder", "Order"), ("AvailableProducts", "CatalogProduct"), ("CancelOrder", "Order"), ("Customer", "Customer"), ("Customers", "Customer"), ("GeocodeCustomerAddress", "Customer"), ("NotificationDeliveries", "Notification"), ("NotificationIntake", "Notification"), ("NotificationPreferences", "Notification"), ("NotificationSourceClaims", "Notification"), ("NotificationSubscriptions", "Notification"), ("Orders", "Order"), ("PlaceOrder", "Order"), ("SendNotification", "Notification"), ("ShipOrder", "Order"), ("SyncCatalogProduct", "CatalogProduct")]),
  )

  let make = () =>
    Platform.Plugin.make(
      ~name="Ordering",
      ~heartbeatInterval=5,
      ~extensionPoints=[module(Orders_ExtensionPoint)],
      ~extensions=[module(Products_Extension)],
      ~aggregates=[module(CustomerAggregate)],
      ~readModels=[module(CustomersReadModel)],
      ~stateChangeSlices=[module(CancelOrderSlice), module(NotificationPreferencesSlice), module(NotificationSourceClaimsSlice), module(PlaceOrderSlice), module(ShipOrderSlice), module(SyncCatalogProductSlice)],
      ~stateViewSlices=[module(AvailableProductsStreamSlice), module(NotificationDeliveriesStreamSlice), module(NotificationSubscriptionsStreamSlice), module(OrdersStreamSlice)],
      ~automationSlices=[module(AutoShipOrderSlice), module(NotificationIntakeSlice)],
      ~outboundTranslationSlices=[module(AnnounceRecipientContactSlice), module(GeocodeCustomerAddressSlice), module(SendNotificationSlice)],
      ~pluginStructure=pluginStructure,
      ~componentRuntime=Dict.fromArray([("Customers", {ReventlessInfra.RuntimeHints.memorySize: Some(2048), timeout: None}), ("Customer", {ReventlessInfra.RuntimeHints.memorySize: Some(1536), timeout: None}), ("PlaceOrder", {ReventlessInfra.RuntimeHints.memorySize: Some(768), timeout: Some(60)}), ("Orders", {ReventlessInfra.RuntimeHints.memorySize: Some(1024), timeout: None})]),
      ~uiFragments=?uiBundleUrl->Option.map(url =>
        Platform.Plugin.makeAutoUIManifest(
          ~remoteEntryUrl=url,
          ~name="Ordering",
          ~pluginStructure,
          ~readModelPositions=["platform-summary"],
          ~aggregatePositions=["resource-detail"],
        )
      ),
    )
}
