// Ordering plugin — platform-agnostic composition root.
// Wires the Customer and Order aggregates and their read models.

open Reventless

module Make = (Platform: Platform.T) => {
  module CustomerAggregate = Platform.Aggregate.Make(
    Customer,
    CustomerBehavior,
    NoEventMappings.Make(Customer),
  )

  module OrderAggregate = Platform.Aggregate.Make(
    Order,
    OrderBehavior,
    NoEventMappings.Make(Order),
  )

  module CustomerMappings: Projection.Mappings with module Target := CustomersReadModel = {
    module CustomerMappings = Projection.Mappings.Make(CustomersReadModel)
    module type Mapping = CustomerMappings.Mapping
    let mappings = CustomersProjections.mappings
  }

  module CustomerReadModel = Platform.ReadModel.Make(CustomersReadModel, CustomerMappings)

  module OrderMappings: Projection.Mappings with module Target := OrdersReadModel = {
    module OrderMappings = Projection.Mappings.Make(OrdersReadModel)
    module type Mapping = OrderMappings.Mapping
    let mappings = OrdersProjections.mappings
  }

  module OrderReadModel = Platform.ReadModel.Make(OrdersReadModel, OrderMappings)
}
