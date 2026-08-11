// ProductDemand StateViewSliceStream.
// Projects catalog events into a per-product demand counter (order count).

@@reventless.spec

// Operator surface: aggregate demand across every customer is a merchandising
// signal, not something a shopper is entitled to read.
@@reventless.authorize(AllowGroups(["Admin"]))

@schema
type consumedEvent =
  | ProductAdded({productId: string, name: string, categoryId: string})
  | ProductDemandRecorded({productId: string})
  | ProductDemandRevoked({productId: string})

// `@id` because this is the one view here whose key cannot be inferred: the state
// carries two `*Id` fields, and the component name yields no matching field
// (`ProductDemand` → `productDemandId`). Without it the generated queryable gets
// no key filter and no order-by at all.
@schema
type state = {@id productId: string, name: string, categoryId: string, orderCount: int}
