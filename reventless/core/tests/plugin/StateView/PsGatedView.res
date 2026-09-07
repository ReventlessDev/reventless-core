// Test fixture spec: a view whose module-level rule restricts who may read it.

@@reventless.spec("GatedView")
@@reventless.authorize(AllowGroups(["Admin"]))

@schema
type consumedEvent = OrderPlaced({orderId: string, customerName: string})

@schema
type state = {orderId: string, customerName: string}

let project = ({event}: Reventless.StateViewSlice.consumed<consumedEvent>) =>
  switch event {
  | OrderPlaced({orderId, customerName}) => [Set(orderId, {orderId, customerName})]
  }
