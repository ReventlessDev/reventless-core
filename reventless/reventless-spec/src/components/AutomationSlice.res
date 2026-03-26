/**
Module type for a DCB automation slice specification (TODO List Pattern).

An `AutomationSlice` listens to the shared `DcbEventLog` event topic, accumulates
pending work items (TODO list), and processes them exactly once by issuing commands.
Completion events mark TODO items as done, closing the automation loop.

```
Event(s) → TODO List (read model) → Processor → Command → Event(s)
```

@example
```rescript
// ShipOrder.res
let name = "ShipOrder"

@schema type todoItem = {orderId: string, shippingAddress: string}
@schema type command = CreateShipment({orderId: @s.matches(DcbTag.string) string, address: string})

let collect = event => switch event {
  | OrderPlaced({orderId, shippingAddress}) =>
    [(orderId, {orderId, shippingAddress})]
  | _ => []
}

let resolve = event => switch event {
  | ShipmentCreated({orderId}) => Some(orderId)
  | _ => None
}

let process = (id, item) =>
  Some((id, CreateShipment({orderId: item.orderId, address: item.shippingAddress})))

let maxRetries = 3
let heartbeatInterval = 60
```
*/
module type Spec = {
  /** Logical name of this automation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /**
  Events this automation slice consumes for collect/resolve.
  Only needs the fields required — no tag annotations needed.
  Must carry `@schema`.
  */
  @schema
  type consumedEvent

  /** The TODO item state — what data is accumulated for each pending work item. Must carry `@schema`. */
  @schema
  type todoItem

  /** The command type produced by the processor. Must carry `@schema`. */
  @schema
  type command

  /**
  Collect: map an incoming event to zero or more new TODO items.
  Each item has an `id` (deduplication key) and the `todoItem` payload.
  Returns empty array if this event is not relevant.
  */
  let collect: consumedEvent => array<(string, todoItem)>

  /**
  Resolve: check if an incoming event completes a pending TODO item.
  Returns `Some(todoItemId)` if the event marks the item as done, `None` otherwise.
  */
  let resolve: consumedEvent => option<string>

  /**
  Process: given a pending TODO item, produce a command.
  The processor calls this for each pending item. Returns the target ID and command.
  May return `None` to skip processing (e.g., wait for more data).
  */
  let process: (string, todoItem) => option<(string, command)>

  /** Maximum number of retries for a failed processing attempt. */
  let maxRetries: int

  /** Heartbeat interval in seconds for sweeping pending/failed items. */
  let heartbeatInterval: int
}
