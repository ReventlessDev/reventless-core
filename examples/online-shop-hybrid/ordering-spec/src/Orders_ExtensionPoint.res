// Orders_ExtensionPoint spec — stable public API from Ordering to Catalog.
// Extensions subscribing to this EP receive per-product order demand events.

@@reventless.spec

@schema
type command = unit // read-only

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

// Non-domain side effects an Extension subscribing to this EP can fire.
// Fired from the SUBSCRIBING side; not durable, not replayable, not routed
// back to the publisher. See
// `catalog/src/Extension/Orders_Extension.res` for the subscriber that emits
// these directives alongside its state-change commands.
@schema
type directive =
  | EmitOrderRecordedTelemetry({productId: string, orderId: string})
  | EmitOrderCancelledTelemetry({productId: string, orderId: string})
