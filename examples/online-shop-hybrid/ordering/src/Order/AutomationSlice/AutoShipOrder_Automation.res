@@reventless.automation

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | OrderShipped(_) => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | OrderPlaced(_) => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))
