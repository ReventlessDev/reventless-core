// Local copy of Ordering's OrdersExtensionPoint spec.
// Must stay in sync with ordering/src/ExtensionPoint/OrdersExtensionPointSpec.res.
// The runtime matches extension points by name, so `name` must be identical.

let name = "Ordering.Orders"

@schema
type command = unit // read-only

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
