open JestGlobals
open ReventlessSeed

// The generated adapter is only worth offering if it sends what the typed one
// sends. For every command the demo seed sends, encode the typed value with
// `DemoCommands`, and its JSON with `Seed.Commands` read from the API's golden
// SDL, and compare the two. Argument order is GraphQL's to ignore, so the
// top-level arguments are compared by name.

@module("./GoldenIntrospection.mjs") external goldenIntrospection: unit => JSON.t = "read"

let commands = Seed.Commands.fromIntrospection(goldenIntrospection())

let sorted = (m: Seed.mutation): string =>
  Seed.describe({...m, args: m.args->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))})

// A command's JSON as its schema writes it: an inline-record arm's fields, with
// the arm's tag dropped; a bare arm has none. An aggregate takes its id beside them.
let argsOf = (json: JSON.t, ~id=?): JSON.t => {
  let fields = switch json {
  | Object(d) =>
    switch d->Dict.get("_0") {
    | Some(Object(inner)) => inner->Dict.copy
    | _ => d->Dict.copy
    }
  | _ => Dict.make()
  }
  fields->Dict.delete("TAG")
  switch id {
  | Some(id) => fields->Dict.set("id", JSON.Encode.string(id))
  | None => ()
  }
  Object(fields)
}

let same = (hand: Seed.mutation, ~schema: S.t<'c>, command: 'c, ~id=?) => {
  let args = command->S.convertOrThrow(~from=schema, ~to=S.json)->argsOf(~id?)
  switch commands->Seed.Commands.encode(~field=hand.field, args) {
  | Ok(generated) => expect(sorted(generated))->toBe(sorted(hand))
  | Error(message) => failwith(`${hand.field}: ${message}`)
  }
}

let categoryId = CatalogPlugin.CategoryId.make("cat-01")
let productId = CatalogSpec.ProductId.make("prd-001")
let orderId = OrderingPlugin.OrderId.make("ord-001")
let customerId = OrderingPlugin.CustomerId.make("cust-01")
let price = Reventless.Money.make(~amount=12.99, ~currency=EUR)
let window =
  Reventless.DateRange.make(
    ~start="2026-11-21T09:00:00.000Z",
    ~end_="2026-11-21T12:00:00.000Z",
  )->Result.getOrThrow

describe("the generated adapter sends what DemoCommands sends:", () => {
  testSync("catalog", () => {
    let s = CatalogPlugin.AddCategory.commandSchema
    let c: CatalogPlugin.AddCategory.command = AddCategory({categoryId, name: "Toys"})
    same(DemoCommands.addCategory(c), ~schema=s, c)

    let s = CatalogPlugin.CategoryImages.commandSchema
    let c: CatalogPlugin.CategoryImages.command = SetCategoryImage({
      categoryId,
      categoryImage: "/category-images/a.png",
      altText: "A",
    })
    same(DemoCommands.categoryImages(c), ~schema=s, c)
    let c: CatalogPlugin.CategoryImages.command = SetCategoryImage({
      categoryId,
      categoryImage: "/category-images/a.png",
    })
    same(DemoCommands.categoryImages(c), ~schema=s, c)

    let s = CatalogPlugin.ProductImages.commandSchema
    let images: array<CatalogPlugin.ProductImages.command> = [
      AttachProductImage({productId, productImage: "/product-images/p.png", altText: "P"}),
      SetPrimaryProductImage({productId, productImage: "/product-images/p.png"}),
      SetProductImageAltText({productId, productImage: "/product-images/p.png", altText: "Q"}),
    ]
    images->Array.forEach(c => same(DemoCommands.productImages(c), ~schema=s, c))

    let c: CatalogPlugin.RenameCategory.command = RenameCategory({categoryId, name: "Games"})
    same(DemoCommands.renameCategory(c), ~schema=CatalogPlugin.RenameCategory.commandSchema, c)
    let c: CatalogPlugin.ArchiveCategory.command = ArchiveCategory({categoryId: categoryId})
    same(DemoCommands.archiveCategory(c), ~schema=CatalogPlugin.ArchiveCategory.commandSchema, c)
    let c: CatalogPlugin.ArchiveProduct.command = ArchiveProduct({productId: productId})
    same(DemoCommands.archiveProduct(c), ~schema=CatalogPlugin.ArchiveProduct.commandSchema, c)
    let c: CatalogPlugin.DiscontinueProduct.command = DiscontinueProduct({productId: productId})
    same(
      DemoCommands.discontinueProduct(c),
      ~schema=CatalogPlugin.DiscontinueProduct.commandSchema,
      c,
    )
    let c: CatalogPlugin.AddProduct.command = AddProduct({
      productId,
      name: "Kite",
      description: "A kite.",
      price,
      categoryId,
    })
    same(DemoCommands.addProduct(c), ~schema=CatalogPlugin.AddProduct.commandSchema, c)
    let c: CatalogPlugin.ChangeProductPrice.command = ChangeProductPrice({productId, price})
    same(
      DemoCommands.changeProductPrice(c),
      ~schema=CatalogPlugin.ChangeProductPrice.commandSchema,
      c,
    )
    let c: CatalogPlugin.ChangeProductDescription.command = ChangeProductDescription({
      productId,
      description: "Still a kite.",
    })
    same(
      DemoCommands.changeProductDescription(c),
      ~schema=CatalogPlugin.ChangeProductDescription.commandSchema,
      c,
    )
  })

  testSync("an inbound translation's input", () => {
    let input: CatalogPlugin.ImportProduct.externalInput = {
      sku: "SKU-1",
      title: "Kite",
      desc: "A kite.",
      unitPrice: 1299,
      currency: "EUR",
      category: "cat-01",
    }
    same(
      DemoCommands.importProduct(input),
      ~schema=CatalogPlugin.ImportProduct.externalInputSchema,
      input,
    )
  })

  testSync("ordering", () => {
    let s = OrderingPlugin.PlaceOrder.commandSchema
    let lineItems: array<OrderingPlugin.PlaceOrder.lineItem> = [{productId, quantity: 2}]
    let c: OrderingPlugin.PlaceOrder.command = PlaceOrder({
      orderId,
      customerId,
      lineItems,
      shippingMethod: Express,
      deliveryWindow: window,
    })
    same(DemoCommands.placeOrder(c), ~schema=s, c)
    let c: OrderingPlugin.PlaceOrder.command = PlaceOrder({
      orderId,
      customerId,
      lineItems,
      shippingMethod: Standard,
    })
    same(DemoCommands.placeOrder(c), ~schema=s, c)

    let c: OrderingPlugin.ShipOrder.command = ShipOrder({orderId: orderId})
    same(DemoCommands.shipOrder(c), ~schema=OrderingPlugin.ShipOrder.commandSchema, c)
    let c: OrderingPlugin.CancelOrder.command = CancelOrder({orderId: orderId})
    same(DemoCommands.cancelOrder(c), ~schema=OrderingPlugin.CancelOrder.commandSchema, c)
  })

  testSync("an aggregate's commands, with the id beside them", () => {
    let id = "cust-01"
    let customer: array<OrderingPlugin.Customer.command> = [
      Register({email: "a@example.com", address: "1 Road"}),
      UpdateEmail({email: "b@example.com"}),
      UpdateAddress({address: "2 Road"}),
      SetAddressLocation({address: "2 Road", location: {lat: 52.5, lng: 13.4}}),
      Deactivate,
      Reactivate,
    ]
    customer->Array.forEach(
      c =>
        same(DemoCommands.customer(~id, c), ~schema=OrderingPlugin.Customer.commandSchema, c, ~id),
    )
  })
})
