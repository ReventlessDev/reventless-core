// Orders_ExtensionPoint spec — stable public API from Ordering to Catalog.
// Extensions subscribing to this EP receive per-product order demand events.

@@reventless.spec

@schema
type command = unit // read-only

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
