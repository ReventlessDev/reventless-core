@@reventless.behavior

// Stored as immutable arrays (rather than `Set.t`) so each fold yields a fresh
// state — `evolve` returns a new record instead of mutating a shared one. This
// keeps successive `decide` calls (and unit tests) hermetic.
// `shelf` is the shelf's current naming and pricing, kept so a placement can copy
// what it sees onto the event. Neither is a decision input for availability:
// nothing here accepts or rejects on what a product is called or costs.
type shelfProduct = {name: string, price: Reventless.Money.t}

type state = {
  placedOrderIds: array<string>,
  availableProductIds: array<string>,
  shelf: array<(string, shelfProduct)>,
  productImages: array<(string, Reventless.UploadableImage.t)>,
}

let initialState = {
  placedOrderIds: [],
  availableProductIds: [],
  shelf: [],
  productImages: [],
}

// Last writer wins, which is what a rename is: the pair is replaced rather than
// appended, so the fold does not grow without bound as a product is renamed.
let replacing = (pairs, productId, value) =>
  pairs->Array.filter(((id, _)) => id != productId)->Array.concat([(productId, value)])

let without = (pairs, productId) => pairs->Array.filter(((id, _)) => id != productId)

let lookup = (pairs, productId) =>
  pairs->Array.find(((id, _)) => id == productId)->Option.map(((_, value)) => value)

let evolve = (state, event: consumedEvent) =>
  switch event {
  | OrderPlaced({orderId}) => {
      ...state,
      placedOrderIds: state.placedOrderIds->Array.includes(orderId)
        ? state.placedOrderIds
        : Array.concat(state.placedOrderIds, [orderId]),
    }
  | CatalogProductSynced({productId, name, price})
  | CatalogProductRelisted({productId, name, price}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.includes(productId)
        ? state.availableProductIds
        : Array.concat(state.availableProductIds, [productId]),
      shelf: state.shelf->replacing(productId, {name, price}),
    }
  // A repricing of something the fold has never seen is dropped: there is no name
  // to attach it to, and inventing one would put a nameless line on an order.
  | CatalogProductPriceChanged({productId, price}) => {
      ...state,
      shelf: switch state.shelf->lookup(productId) {
      | Some(product) => state.shelf->replacing(productId, {...product, price})
      | None => state.shelf
      },
    }
  // Clears as well as sets. A product whose last picture was removed *before*
  // an order is placed must record no picture — freezing the one it used to have
  // would not be a record of the purchase, it would be staleness.
  | CatalogProductImageChanged({productId, ?productImage}) => {
      ...state,
      productImages: switch productImage {
      | Some(image) => state.productImages->replacing(productId, image)
      | None => state.productImages->without(productId)
      },
    }
  // The half that was missing: without it the set only ever grows, and a
  // withdrawn product stays orderable. Removing the id is what keeps this
  // decision agreeing with the `AvailableProducts` view, which deletes the row.
  | CatalogProductWithdrawn({productId}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.filter(id => id != productId),
    }
  }

// An order for the same thing twice is one line of two. Merging at the decision
// keeps the read side and the extension point from having to think about it at
// all; first appearance sets the position, so the order reads the way it was
// entered.
let mergeLines = (lineItems: array<lineItem>): array<lineItem> =>
  lineItems->Array.reduce([], (merged: array<lineItem>, {productId, quantity}: lineItem) =>
    switch merged->Array.findIndex(line => line.productId == productId) {
    | -1 => merged->Array.concat([{productId, quantity}])
    | at =>
      merged->Array.mapWithIndex((line, i) =>
        i == at ? {...line, quantity: line.quantity + quantity} : line
      )
    }
  )

// Prices one merged line from the shelf as the fold holds it. `Money.times` owns
// the multiplication — `amount *. float(quantity)` here is exactly the arithmetic
// that module exists to keep out of a behaviour — and refuses a product past the
// range where a float is still an exact integer, which is a quantity nobody meant.
let priceLine = (state, {productId, quantity}: lineItem): result<orderLine, error> =>
  switch state.shelf->lookup(productId) {
  | None => Error(ProductsNotAvailable({missing: [productId]}))
  | Some({name, price}) =>
    switch price->Reventless.Money.times(~by=quantity) {
    | Error(_) => Error(InvalidQuantity({productId, quantity}))
    | Ok(lineTotal) => Ok({productId, name, quantity, unitPrice: price, lineTotal})
    }
  }

let priceLines = (state, lineItems: array<lineItem>): result<array<orderLine>, error> =>
  lineItems->Array.reduce(Ok([]), (acc, lineItem) =>
    switch (acc, priceLine(state, lineItem)) {
    | (Error(_) as failed, _) => failed
    | (_, Error(_) as failed) => failed
    | (Ok(lines), Ok(line)) => Ok(lines->Array.concat([line]))
    }
  )

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, lineItems, shippingMethod, ?deliveryWindow}) =>
    if state.placedOrderIds->Array.includes(orderId) {
      Error(OrderAlreadyPlaced)
    } else if lineItems->Array.length == 0 {
      Error(OrderIsEmpty)
    } else {
      switch lineItems->Array.find(({quantity}) => quantity <= 0) {
      | Some({productId, quantity}) => Error(InvalidQuantity({productId, quantity}))
      | None =>
        let merged = mergeLines(lineItems)
        let missing =
          merged->Array.filterMap(({productId}) =>
            state.availableProductIds->Array.includes(productId) ? None : Some(productId)
          )
        if missing->Array.length > 0 {
          Error(ProductsNotAvailable({missing: missing}))
        } else {
          switch priceLines(state, merged) {
          | Error(_) as failed => failed
          | Ok(lines) =>
            switch lines->Array.map(line => line.lineTotal)->Reventless.Money.sum {
            | None => Error(OrderIsEmpty)
            | Some(Error(_)) =>
              Error(
                MixedCurrencies({
                  currencies: lines->Array.reduce([], (codes, line) => {
                    let code = line.unitPrice.currency->Reventless.Currency.toString
                    codes->Array.includes(code) ? codes : codes->Array.concat([code])
                  }),
                }),
              )
            | Some(Ok(total)) =>
              // The first product's name as the shelf reads it *now*, copied onto
              // the event so the order keeps it. `None` where the fold has not
              // seen a name — an order placed against a product synced before
              // names were carried.
              let first = lines->Array.get(0)->Option.map(line => line.productId)
              let firstProductName = lines->Array.get(0)->Option.map(line => line.name)
              let firstProductImage = first->Option.flatMap(id => state.productImages->lookup(id))
              Ok([
                OrderPlaced({
                  orderId,
                  customerId,
                  productIds: lines->Array.map(line => line.productId),
                  lines,
                  total,
                  shippingMethod,
                  ?deliveryWindow,
                  ?firstProductName,
                  ?firstProductImage,
                }),
              ])
            }
          }
        }
      }
    }
  }
