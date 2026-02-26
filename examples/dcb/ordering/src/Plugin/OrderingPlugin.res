// Ordering DCB plugin — platform-agnostic composition root.
// Wires the shared event log, all StateChangeSlices, and StateViewSlices for Customer and Order.

open Reventless
module Make = (Platform: Platform.T) => {
  module OrderingEventLogMaker = Platform.DcbEventLog.Make(OrderingEventLog)

  module RegisterCustomerSlice = Platform.StateChangeSlice.Make(RegisterCustomer)
  module UpdateEmailSlice = Platform.StateChangeSlice.Make(UpdateEmail)
  module UpdateAddressSlice = Platform.StateChangeSlice.Make(UpdateAddress)
  module DeactivateCustomerSlice = Platform.StateChangeSlice.Make(DeactivateCustomer)

  module CustomersViewSlice = Platform.StateViewSlice.Make(CustomersView)

  module PlaceOrderSlice = Platform.StateChangeSlice.Make(PlaceOrder)
  module ShipOrderSlice = Platform.StateChangeSlice.Make(ShipOrder)
  module CancelOrderSlice = Platform.StateChangeSlice.Make(CancelOrder)

  module OrdersViewSlice = Platform.StateViewSlice.Make(OrdersView)

  module DcbSpec = OrderingEventLog
}
