// OrdersExtensionPoint spec — stable public API from Ordering
@@reventless.spec

@schema
type command = unit // read-only: no inbound commands

@schema
type event =
  | ItemOrdered({productId: string, orderId: string, customerId: string})
  | ItemOrderCancelled({productId: string, orderId: string})

@schema
type directive = unit
