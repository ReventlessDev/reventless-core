// Test fixture spec where every reference carrier is one the naive walk misses:
// PLURAL, or declared on a field of a record the command holds.
//
// `Reference.to_` returns an *element* schema, so the ppx annotates the `string`
// inside `array<string>` and the field's own schema carries no marker. A walk
// that asks the field directly finds nothing and drops the declaration — and a
// dropped `@ref` is not the same as an absent one: the consuming side falls back
// to a naming heuristic and resolves the field to whatever entity the name
// suggests, so the author's declaration is both ignored and reported as missing.
//
// The command declares the scalar and plural forms side by side so a regression
// shows up as one of the two disappearing rather than as an empty list, and
// `warehouseIds?` covers the plural-inside-optional shape, where the array sits
// one wrapper further down still.
//
// `lineItems` covers the other shape the walk has to descend into: a reference
// declared on a field of a record the command holds, which belongs to that field
// and is named by its path. A named record type, not an inline one — the ppx
// walks a type declaration, which is what puts the marker on `productId` at all.

@@reventless.spec("ReserveStock")

type state = bool
let initialState = false

@schema
type consumedEvent = StockReserved({reservationId: string})

let evolve = (_state, _event) => true

@schema
type lineItem = {
  @ref("AvailableProducts") productId: string,
  quantity: int,
}

@schema
type command =
  | ReserveStock({
      @partitionTag reservationId: string,
      @ref("Customers") customerId: string,
      @ref("AvailableProducts") productIds: array<string>,
      @ref("Warehouses") warehouseIds?: array<string>,
      lineItems: array<lineItem>,
    })

@schema
type error = OutOfStock

@schema
type event =
  StockReserved({
    @partitionTag reservationId: string,
    @ref("AvailableProducts") productIds: array<string>,
  })

let decide = (_state, _command): result<array<event>, error> => Ok([])
