// Adapter: online-shop-hybrid command values → GraphQL mutations.
//
// This is the only place that knows how this example's commands are exposed on
// the API — the mutation field names and how each variant's payload maps onto
// arguments. Everything above it works in plugin command types; everything
// below it (`ReventlessSeed`) works in generic mutations.
//
// Each encoder pattern-matches the real command variant, so a renamed field or
// a new payload member is a compile error here rather than a rejected mutation
// at seed time. That is the whole point of routing the seed through typed
// commands instead of hand-written GraphQL strings.

open ReventlessSeed

// Mutation fields are `<PluginName>_<CommandVariant>`; aggregates additionally
// carry the entity id as a separate `id` argument.
let catalog = (name: string): string => `Catalog_${name}`
let ordering = (name: string): string => `Ordering_${name}`

/** A `Money.t` argument is a GraphQL input object, and its currency is an
    *enum* rather than a string — the closed ReScript type reaches the API as a
    closed GraphQL type. Quoting it here would be rejected by the server, which
    is the one detail worth centralising in this file. */
let money = (m: Reventless.Money.t): Seed.value =>
  Object([
    ("amount", Float(m.amount)),
    ("currency", Enum(Reventless.Currency.toString(m.currency))),
  ])

/** A `DateRange.t` argument is a GraphQL input object of two ISO instants. `end`
    is the wire field name (`@as("end")` in the type), so it is `end` here too —
    the composite reaches the API as one nested input, not a guessed field pair. */
let dateRange = (r: Reventless.DateRange.t): Seed.value =>
  Object([("start", String(r.start)), ("end", String(r.end_))])

// ── Catalog ─────────────────────────────────────────────────────────────────

let addCategory = (command: CatalogPlugin.AddCategory.command): Seed.mutation =>
  switch command {
  | AddCategory({categoryId, name}) =>
    Seed.mutation(catalog("AddCategory"), [("categoryId", Id(categoryId)), ("name", String(name))])
  }

let renameCategory = (command: CatalogPlugin.RenameCategory.command): Seed.mutation =>
  switch command {
  | RenameCategory({categoryId, name}) =>
    Seed.mutation(
      catalog("RenameCategory"),
      [("categoryId", Id(categoryId)), ("name", String(name))],
    )
  }

let archiveCategory = (command: CatalogPlugin.ArchiveCategory.command): Seed.mutation =>
  switch command {
  | ArchiveCategory({categoryId}) =>
    Seed.mutation(catalog("ArchiveCategory"), [("categoryId", Id(categoryId))])
  }

let addProduct = (command: CatalogPlugin.AddProduct.command): Seed.mutation =>
  switch command {
  | AddProduct({productId, name, description, price, imageUrl: ?imageUrl, categoryId}) =>
    // imageUrl is optional: include the (nullable) arg only when present, so an
    // image-less product sends no image rather than an empty string.
    let base: array<(string, Seed.value)> = [
      ("productId", Id(productId)),
      ("name", String(name)),
      ("description", String(description)),
      ("price", money(price)),
    ]
    let image: array<(string, Seed.value)> = switch imageUrl {
    | Some(url) => [("imageUrl", String(url))]
    | None => []
    }
    let tail: array<(string, Seed.value)> = [("categoryId", Id(categoryId))]
    Seed.mutation(catalog("AddProduct"), Array.concat(Array.concat(base, image), tail))
  }

let changeProductPrice = (command: CatalogPlugin.ChangeProductPrice.command): Seed.mutation =>
  switch command {
  | ChangeProductPrice({productId, price}) =>
    Seed.mutation(
      catalog("ChangeProductPrice"),
      [("productId", Id(productId)), ("price", money(price))],
    )
  }

let changeProductDescription = (
  command: CatalogPlugin.ChangeProductDescription.command,
): Seed.mutation =>
  switch command {
  | ChangeProductDescription({productId, description}) =>
    Seed.mutation(
      catalog("ChangeProductDescription"),
      [("productId", Id(productId)), ("description", String(description))],
    )
  }

/** InboundTranslationSlice: the mutation arguments are the external input's
    fields, not a command payload — the slice translates them itself. */
let importProduct = (input: CatalogPlugin.ImportProduct.externalInput): Seed.mutation =>
  Seed.mutation(
    catalog("ImportProduct"),
    [
      ("sku", String(input.sku)),
      ("title", String(input.title)),
      ("desc", String(input.desc)),
      ("unitPrice", Int(input.unitPrice)),
      ("currency", String(input.currency)),
      ("category", Id(input.category)),
    ],
  )

// ── Ordering ────────────────────────────────────────────────────────────────

let shippingMethod = (method: OrderingPlugin.PlaceOrder.shippingMethod): Seed.value =>
  switch method {
  | Standard => Enum("Standard")
  | Express => Enum("Express")
  | Pickup => Enum("Pickup")
  }

let placeOrder = (command: OrderingPlugin.PlaceOrder.command): Seed.mutation =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds, shippingMethod: method, deliveryWindow: ?window}) =>
    let base: array<(string, Seed.value)> = [
      ("orderId", Id(orderId)),
      ("customerId", Id(customerId)),
      ("productIds", Seed.ids(productIds)),
      ("shippingMethod", shippingMethod(method)),
    ]
    // The delivery window is optional: send the (nested input object) arg only
    // when the order asked for one, so an order with no preference sends none.
    Seed.mutation(
      ordering("PlaceOrder"),
      switch window {
      | Some(w) => base->Array.concat([("deliveryWindow", dateRange(w))])
      | None => base
      },
    )
  }

let shipOrder = (command: OrderingPlugin.ShipOrder.command): Seed.mutation =>
  switch command {
  | ShipOrder({orderId}) => Seed.mutation(ordering("ShipOrder"), [("orderId", Id(orderId))])
  }

/** CancelOrder's ReopenOrder variant is `@noApi`, so it has no mutation field to
    encode to — reaching it here means the seed tried to drive an internal-only
    command through the public API. */
let cancelOrder = (command: OrderingPlugin.CancelOrder.command): Seed.mutation =>
  switch command {
  | CancelOrder({orderId}) => Seed.mutation(ordering("CancelOrder"), [("orderId", Id(orderId))])
  | ReopenOrder(_) =>
    throw(Seed.Failed("ReopenOrder is @noApi — it cannot be seeded through the GraphQL API"))
  }

/** Aggregate commands are exposed as `<Plugin>_<Aggregate>_<Variant>` and take
    the aggregate id alongside the payload. */
let customer = (~id: string, command: OrderingPlugin.Customer.command): Seed.mutation =>
  switch command {
  | Register({email, address}) =>
    Seed.mutation(
      ordering("Customer_Register"),
      [("id", Id(id)), ("email", String(email)), ("address", String(address))],
    )
  | UpdateEmail({email}) =>
    Seed.mutation(ordering("Customer_UpdateEmail"), [("id", Id(id)), ("email", String(email))])
  | UpdateAddress({address}) =>
    Seed.mutation(
      ordering("Customer_UpdateAddress"),
      [("id", Id(id)), ("address", String(address))],
    )
  | SetLocation({location}) =>
    Seed.mutation(
      ordering("Customer_SetLocation"),
      [("id", Id(id)), ("location", Object([("lat", Float(location.lat)), ("lng", Float(location.lng))]))],
    )
  | Deactivate => Seed.mutation(ordering("Customer_Deactivate"), [("id", Id(id))])
  }
