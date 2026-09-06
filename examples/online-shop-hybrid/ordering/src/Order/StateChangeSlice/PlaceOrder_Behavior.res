@@reventless.behavior

// Stored as immutable arrays (rather than `Set.t`) so each fold yields a fresh
// state — `evolve` returns a new record instead of mutating a shared one. This
// keeps successive `decide` calls (and unit tests) hermetic.
// `productNames` is the shelf's current naming, kept only so a placement can
// copy the name it sees into the event. It is not a decision input: nothing here
// accepts or rejects on what a product is called.
type state = {
  placedOrderIds: array<string>,
  availableProductIds: array<string>,
  productNames: array<(string, string)>,
  productImages: array<(string, Reventless.UploadableImage.t)>,
}

let initialState = {
  placedOrderIds: [],
  availableProductIds: [],
  productNames: [],
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
  | CatalogProductSynced({productId, name})
  | CatalogProductRelisted({productId, name}) => {
      ...state,
      availableProductIds: state.availableProductIds->Array.includes(productId)
        ? state.availableProductIds
        : Array.concat(state.availableProductIds, [productId]),
      productNames: state.productNames->replacing(productId, name),
    }
  // Clears as well as sets. A product whose last picture was removed *before*
  // an order is placed must record no picture — freezing the one it used to have
  // would not be a record of the purchase, it would be staleness.
  | CatalogProductImageChanged({productId, productImage: ?productImage}) => {
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

let decide = (state, command) =>
  switch command {
  | PlaceOrder({orderId, customerId, productIds, shippingMethod, deliveryWindow: ?deliveryWindow}) =>
    if state.placedOrderIds->Array.includes(orderId) {
      Error(OrderAlreadyPlaced)
    } else {
      let missing = productIds->Array.filter(pid => !(state.availableProductIds->Array.includes(pid)))
      if missing->Array.length > 0 {
        Error(ProductsNotAvailable({missing: missing}))
      } else {
        // The first product's name as the shelf reads it *now*, copied onto the
        // event so the order keeps it. `None` where the fold has not seen a name
        // — an order placed against a product synced before names were carried.
        let first = productIds->Array.get(0)
        let firstProductName = first->Option.flatMap(id => state.productNames->lookup(id))
        let firstProductImage = first->Option.flatMap(id => state.productImages->lookup(id))
        Ok([
          OrderPlaced({
            orderId,
            customerId,
            productIds,
            shippingMethod,
            deliveryWindow: ?deliveryWindow,
            firstProductName: ?firstProductName,
            firstProductImage: ?firstProductImage,
          }),
        ])
      }
    }
  }
