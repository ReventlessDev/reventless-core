// What a follow-up run reads before deciding what to send: the shop as its views
// show it now, through the same GraphQL API the commands go through.
//
// Retired rows are read too (`includeRetired`), so an archived product or a
// deactivated customer is known to be there rather than mistaken for a gap.

open ReventlessSeed

type product = {
  id: string,
  categoryId: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  listed: bool,
}

type category = {id: string, listed: bool}

type customer = {id: string, active: bool}

type availableProduct = {id: string, price: Reventless.Money.t}

type order = {
  id: string,
  customerId: string,
  placed: bool,
  shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod,
  deliveryWindow: option<Reventless.DateRange.t>,
}

type t = {
  products: array<product>,
  categories: array<category>,
  // What Ordering can sell now: the products that crossed the extension point
  // and have not been withdrawn since, at the price Ordering holds.
  availableProducts: array<availableProduct>,
  customers: array<customer>,
  orders: array<order>,
}

let string = (node, key) => node->Seed.Client.nodeString(key)->Option.getOr("")

let moneyOf = (node: JSON.t): option<Reventless.Money.t> =>
  switch (
    node->Seed.Client.field("amount"),
    node->Seed.Client.nodeString("currency")->Option.map(Reventless.Currency.fromString),
  ) {
  | (Some(Number(amount)), Some(Ok(currency))) => Some(Reventless.Money.make(~amount, ~currency))
  | _ => None
  }

let windowOf = (node: JSON.t): option<Reventless.DateRange.t> =>
  switch (node->Seed.Client.nodeString("start"), node->Seed.Client.nodeString("end")) {
  | (Some(start), Some(end_)) => Some({start, end_})
  | _ => None
  }

let shippingMethodOf = (raw: string): option<OrderingPlugin.PlaceOrder.shippingMethod> =>
  switch raw {
  | "Standard" => Some(Standard)
  | "Express" => Some(Express)
  | "Pickup" => Some(Pickup)
  | _ => None
  }

let productOf = (node: JSON.t): option<product> =>
  node
  ->Seed.Client.field("price")
  ->Option.flatMap(moneyOf)
  ->Option.map(price => {
    id: string(node, "productId"),
    categoryId: string(node, "categoryId"),
    name: string(node, "name"),
    description: string(node, "description"),
    price,
    listed: string(node, "shelfStatus") == "Listed",
  })

let orderOf = (node: JSON.t): option<order> =>
  string(node, "shippingMethod")
  ->shippingMethodOf
  ->Option.map(shippingMethod => {
    id: string(node, "orderId"),
    customerId: string(node, "customerId"),
    placed: string(node, "lifecycle") == "Placed",
    shippingMethod,
    deliveryWindow: node->Seed.Client.field("deliveryWindow")->Option.flatMap(windowOf),
  })

let read = async (client: Seed.Client.t): t => {
  let retired = "includeRetired: true"
  let products = await client->Seed.Client.queryAllNodes(
    ~field="Catalog_Products",
    ~selection="productId categoryId name description shelfStatus price { amount currency }",
    ~args=retired,
  )
  let categories = await client->Seed.Client.queryAllNodes(
    ~field="Catalog_Categories",
    ~selection="categoryId shelfStatus",
    ~args=retired,
  )
  let available = await client->Seed.Client.queryAllNodes(
    ~field="Ordering_AvailableProducts",
    ~selection="productId price { amount currency }",
  )
  let customers = await client->Seed.Client.queryAllNodes(
    ~field="Ordering_Customers",
    ~selection="customerId accountStatus",
    ~args=retired,
  )
  let orders = await client->Seed.Client.queryAllNodes(
    ~field="Ordering_Orders",
    ~selection="orderId customerId lifecycle shippingMethod deliveryWindow { start end }",
  )
  {
    products: products->Array.filterMap(productOf),
    categories: categories->Array.map(node => {
      id: string(node, "categoryId"),
      listed: string(node, "shelfStatus") == "Listed",
    }),
    availableProducts: available->Array.filterMap(node =>
      node
      ->Seed.Client.field("price")
      ->Option.flatMap(moneyOf)
      ->Option.map(price => {id: string(node, "productId"), price})
    ),
    customers: customers->Array.map(node => {
      id: string(node, "customerId"),
      active: string(node, "accountStatus") == "Active",
    }),
    orders: orders->Array.filterMap(orderOf),
  }
}
