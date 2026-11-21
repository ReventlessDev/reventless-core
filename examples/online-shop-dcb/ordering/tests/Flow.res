// AUTO-GENERATED — do not edit. Run `npm run generate` to update.

// A flow's steps, one per part, under the part's own name.

// Decisions
module CancelOrder = ReventlessGwt.Flow_GWT.DecisionStep(CancelOrder, CancelOrder_Decision)
module ChangeAddress = ReventlessGwt.Flow_GWT.DecisionStep(ChangeAddress, ChangeAddress_Decision)
module ChangeEmail = ReventlessGwt.Flow_GWT.DecisionStep(ChangeEmail, ChangeEmail_Decision)
module DeactivateCustomer = ReventlessGwt.Flow_GWT.DecisionStep(
  DeactivateCustomer,
  DeactivateCustomer_Decision,
)
module PlaceOrder = ReventlessGwt.Flow_GWT.DecisionStep(PlaceOrder, PlaceOrder_Decision)
module RegisterCustomer = ReventlessGwt.Flow_GWT.DecisionStep(
  RegisterCustomer,
  RegisterCustomer_Decision,
)
module ShipOrder = ReventlessGwt.Flow_GWT.DecisionStep(ShipOrder, ShipOrder_Decision)
module SyncCatalogProduct = ReventlessGwt.Flow_GWT.DecisionStep(
  SyncCatalogProduct,
  SyncCatalogProduct_Decision,
)

// Views
module AvailableProducts = ReventlessGwt.Flow_GWT.ViewStep(
  AvailableProducts,
  AvailableProducts_Projection,
)
module Customers = ReventlessGwt.Flow_GWT.ViewStep(Customers, Customers_Projection)
module Orders = ReventlessGwt.Flow_GWT.ViewStep(Orders, Orders_Projection)

// Automations
module AutoShipOrder = ReventlessGwt.Flow_GWT.AutomationStep(
  AutoShipOrder,
  AutoShipOrder_Automation,
)

// Ways out
module SendOrderConfirmation = ReventlessGwt.Flow_GWT.OutboundStep(
  SendOrderConfirmation,
  SendOrderConfirmation_Translation,
)

// Extension points
module Orders_ExtensionPoint = ReventlessGwt.Flow_GWT.ExtensionPointStep(
  Orders_ExtensionPointMapping,
)

// Extensions
module Products_Extension = ReventlessGwt.Flow_GWT.ExtensionStep(Products_Extension.Mapping)
