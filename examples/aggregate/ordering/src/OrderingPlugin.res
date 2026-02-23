// Ordering plugin — platform-agnostic composition root.
// Wires the Customer and Order aggregates and their read models.

open ReventlessSpec
open Reventless.Projection

module Make = (Platform: Platform.T) => {
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    CustomerBehavior,
    Reventless.NoEventMappings.Make(Customer),
  )

  module OrderAggregate = Platform.Aggregate.Make(
    Order,
    OrderBehavior,
    Reventless.NoEventMappings.Make(Order),
  )

  module CustomerMappings: Projection.Mappings with module Target := CustomersReadModel = {
    module CustomerMappings = Mappings.Make(CustomersReadModel)
    module type Mapping = CustomerMappings.Mapping
    let mappings = CustomersProjections.mappings
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerMappings)

  module OrderMappings: Projection.Mappings with module Target := OrdersReadModel = {
    module OrderMappings = Mappings.Make(OrdersReadModel)
    module type Mapping = OrderMappings.Mapping
    let mappings = OrdersProjections.mappings
  }

  module OrderReadModel = Platform.ReadModel.Make(OrdersReadModel, OrderMappings)
}
