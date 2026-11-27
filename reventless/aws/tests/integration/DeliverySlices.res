// A shop's delivery fees: one fee per delivery option, and an order that quotes the fee of every
// option. The order decides by its own id and reads every fee: a kind read whole.
//
// Hand-written `@s.matches(...)` markers and `DcbTag.readWhole`: the reventless-ppx is not wired
// into this package (see `EpTestSlice`).

module Defaults = {
  type role = Reventless.Role.name
  let authorizationOf = (_: string): Reventless.Authorization.rule<role> => AllowAnonymous
  type lifecycleState = unit
  let traits: array<Reventless.Trait.t> = []
  let readConsistency = Reventless.ReadConsistency.EscalateOnRetry
}

module SetDeliveryFee = {
  include Defaults
  let name = "SetDeliveryFee"
  let moduleUrl = "delivery://src/Delivery/StateChange/SetDeliveryFee.res.mjs"

  @schema
  type consumedEvent = DeliveryFeeSet({deliveryOptionId: string, fee: float})
  @schema
  type command =
    SetDeliveryFee({deliveryOptionId: @s.matches(Reventless.DcbTag.string) string, fee: float})
  @schema
  type error = unit
  @schema
  type event =
    DeliveryFeeSet({deliveryOptionId: @s.matches(Reventless.DcbTag.partition) string, fee: float})

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module SetDeliveryFeeDecision = {
  type state = option<float>
  let initialState = None
  let evolve = (_, event: SetDeliveryFee.consumedEvent) =>
    switch event {
    | DeliveryFeeSet({fee}) => Some(fee)
    }
  let decide = (current, SetDeliveryFee.SetDeliveryFee({deliveryOptionId, fee})) =>
    current == Some(fee) ? Ok([]) : Ok([SetDeliveryFee.DeliveryFeeSet({deliveryOptionId, fee})])
  let moduleUrl = "delivery://SetDeliveryFeeDecision"
}

module PlaceOrder = {
  include Defaults
  let name = "PlaceOrder"
  let moduleUrl = "delivery://src/Order/StateChange/PlaceOrder.res.mjs"

  @schema
  type quoteLine = {deliveryOption: string, fee: float}

  @schema
  type consumedEvent =
    | OrderPlaced({orderId: string})
    | DeliveryFeeSet({deliveryOptionId: string, fee: float})
  let consumedEventSchema = consumedEventSchema->Reventless.DcbTag.readWhole(["DeliveryFeeSet"])
  @schema
  type command = PlaceOrder({orderId: @s.matches(Reventless.DcbTag.string) string})
  @schema
  type error = AlreadyPlaced
  @schema
  type event =
    OrderPlaced({orderId: @s.matches(Reventless.DcbTag.partition) string, quote: array<quoteLine>})

  let commandTransition = (_: command): Reventless.Transition.t<lifecycleState> => Unrestricted
}

module PlaceOrderDecision = {
  type state = {placed: bool, fees: array<PlaceOrder.quoteLine>}
  let initialState = {placed: false, fees: []}
  let evolve = (state, event: PlaceOrder.consumedEvent) =>
    switch event {
    | OrderPlaced(_) => {...state, placed: true}
    | DeliveryFeeSet({deliveryOptionId, fee}) => {
        ...state,
        fees: state.fees
        ->Array.filter(l => l.deliveryOption != deliveryOptionId)
        ->Array.concat([{deliveryOption: deliveryOptionId, fee}]),
      }
    }
  let decide = (state, PlaceOrder.PlaceOrder({orderId})) =>
    state.placed
      ? Error(PlaceOrder.AlreadyPlaced)
      : Ok([
          PlaceOrder.OrderPlaced({
            orderId,
            quote: state.fees->Array.toSorted((a, b) =>
              String.compare(a.deliveryOption, b.deliveryOption)
            ),
          }),
        ])
  let moduleUrl = "delivery://PlaceOrderDecision"
}
