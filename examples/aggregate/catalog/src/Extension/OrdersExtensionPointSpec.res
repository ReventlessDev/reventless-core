// Local copy of Ordering's OrdersExtensionPoint spec.
// Must match name = "Ordering.Orders" exactly.

let name = "Ordering.Orders"

@schema
type command = unit

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
