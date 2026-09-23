// Boundary GWT for Catalog's Orders extension: public Ordering events become
// RecordProductDemand commands on Catalog's demand slice.
@@reventless.gwt

open Catalog_Examples

// `Mapping` is brought into scope by the PPX `open Orders_Extension`; opening
// it surfaces the extension point's events and the delegate's commands.
open Mapping

// Each `ItemOrdered` / `ItemOrderCancelled` produces TWO actions on disjoint
// channels: a `RecordDemand` / `RevokeDemand` command, and a telemetry
// directive. Per-channel tests project to one channel each.
describe("Orders Extension delegate", () => {
  // scenario-id: ec2d0611-869c-415e-bf30-23b0f360fcf5
  test("ItemOrdered records demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
    )->thenPublishesCommand(Delegate.RecordDemand({productId: p1, orderId: "o1"}))
  )

  // scenario-id: 26131567-5602-40a0-9142-bdaeceb4fc13
  test("ItemOrdered fires an order-recorded telemetry directive", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrdered({productId: "p1", orderId: "o1", customerId: "c1"}),
    )->thenHandlesDirective(
      ExtensionPoint.EmitOrderRecordedTelemetry({productId: "p1", orderId: "o1"}),
    )
  )

  // scenario-id: 5b997b27-35f1-4650-b912-abdddd9e53f5
  test("ItemOrderCancelled revokes demand for the product", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"}),
    )->thenPublishesCommand(Delegate.RevokeDemand({productId: p1, orderId: "o1"}))
  )

  // scenario-id: 08ba1385-64e6-488d-98a3-ef62d35f1df2
  test("ItemOrderCancelled fires an order-cancelled telemetry directive", () =>
    whenIncomingEvent(
      ExtensionPoint.ItemOrderCancelled({productId: "p1", orderId: "o1"}),
    )->thenHandlesDirective(
      ExtensionPoint.EmitOrderCancelledTelemetry({productId: "p1", orderId: "o1"}),
    )
  )
})
