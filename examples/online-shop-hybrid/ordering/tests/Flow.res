// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module CancelOrder = ReventlessGwt.Flow_GWT.DecisionStep(CancelOrder, CancelOrder_Decision)
module EmailVerificationChallenges = ReventlessGwt.Flow_GWT.DecisionStep(
  EmailVerificationChallenges,
  EmailVerificationChallenges_Decision,
)
module NotificationPreferences = ReventlessGwt.Flow_GWT.DecisionStep(
  NotificationPreferences,
  NotificationPreferences_Decision,
)
module NotificationSourceClaims = ReventlessGwt.Flow_GWT.DecisionStep(
  NotificationSourceClaims,
  NotificationSourceClaims_Decision,
)
module PlaceOrder = ReventlessGwt.Flow_GWT.DecisionStep(PlaceOrder, PlaceOrder_Decision)
module ShipOrder = ReventlessGwt.Flow_GWT.DecisionStep(ShipOrder, ShipOrder_Decision)
module SyncCatalogProduct = ReventlessGwt.Flow_GWT.DecisionStep(
  SyncCatalogProduct,
  SyncCatalogProduct_Decision,
)

// Aggregates
module Customer = ReventlessGwt.Flow_GWT.AggregateStep(Customer, Customer_Decision)

// Views
module AvailableProducts = ReventlessGwt.Flow_GWT.ViewStep(
  AvailableProducts,
  AvailableProducts_Projection,
)
module NotificationDeliveries = ReventlessGwt.Flow_GWT.ViewStep(
  NotificationDeliveries,
  NotificationDeliveries_Projection,
)
module NotificationSubscriptions = ReventlessGwt.Flow_GWT.ViewStep(
  NotificationSubscriptions,
  NotificationSubscriptions_Projection,
)
module Orders = ReventlessGwt.Flow_GWT.ViewStep(Orders, Orders_Projection)

// Automations
module AutoShipOrder = ReventlessGwt.Flow_GWT.AutomationStep(
  AutoShipOrder,
  AutoShipOrder_Automation,
)
module CancelUnshippedOrder = ReventlessGwt.Flow_GWT.AutomationStep(
  CancelUnshippedOrder,
  CancelUnshippedOrder_Automation,
)
module MarketingDigest = ReventlessGwt.Flow_GWT.AutomationStep(
  MarketingDigest,
  MarketingDigest_Automation,
)
module NotificationIntake = ReventlessGwt.Flow_GWT.AutomationStep(
  NotificationIntake,
  NotificationIntake_Automation,
)

// Ways out
module AnnounceRecipientContact = ReventlessGwt.Flow_GWT.OutboundStep(
  AnnounceRecipientContact,
  AnnounceRecipientContact_Translation,
)
module GeocodeCustomerAddress = ReventlessGwt.Flow_GWT.OutboundStep(
  GeocodeCustomerAddress,
  GeocodeCustomerAddress_Translation,
)
module SendNotification = ReventlessGwt.Flow_GWT.OutboundStep(
  SendNotification,
  SendNotification_Translation,
)
module VerifyCustomerEmail = ReventlessGwt.Flow_GWT.OutboundStep(
  VerifyCustomerEmail,
  VerifyCustomerEmail_Translation,
)

// Extension points
module Orders_ExtensionPoint = ReventlessGwt.Flow_GWT.ExtensionPointStep(
  Orders_ExtensionPointMapping,
)

// Extensions
module Products_Extension = ReventlessGwt.Flow_GWT.ExtensionStep(Products_Extension.Mapping)
