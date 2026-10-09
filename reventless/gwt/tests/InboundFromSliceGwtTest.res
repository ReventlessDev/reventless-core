// InboundTranslation_GWT.FromSlice: input decoded as it arrives, translated by
// the slice's own `translate`, and commands checked against their schema.

module PaymentHook = {
  let name = "PaymentHook"
  let moduleUrl = ""

  @schema
  type externalInput = {orderId: string, status: string}

  @schema
  type command = ConfirmPayment({orderId: string})

  let targetName = "Order"
  let externalSystem = Some("Payments")
  type role = Reventless.Role.name
  let commandAuthorization = _ => Reventless.Authorization.AllowAuthenticated
  type lifecycleState = unit
  let commandTransition = _ => Reventless.Transition.Unrestricted
}

module PaymentHook_Translation = {
  let moduleUrl = ""
  let translate = (input: PaymentHook.externalInput) =>
    switch input.status {
    | "paid" => Ok([(input.orderId, PaymentHook.ConfirmPayment({orderId: input.orderId}))])
    | "pending" => Ok([])
    | other => Error(`Unknown status: ${other}`)
    }
}

open PaymentHook
include InboundTranslation_GWT.FromSlice(PaymentHook, PaymentHook_Translation)

let json = (pairs: array<(string, string)>) =>
  pairs->Array.map(((k, v)) => (k, JSON.Encode.string(v)))->Dict.fromArray->JSON.Encode.object

describe("InboundTranslation_GWT.FromSlice", () => {
  test("input translates to a command", () =>
    whenInput({orderId: "o1", status: "paid"})->thenCommand("o1", ConfirmPayment({orderId: "o1"}))
  )

  test("received JSON decodes before it translates", () =>
    whenReceived(json([("orderId", "o1"), ("status", "paid")]))->thenCommand(
      "o1",
      ConfirmPayment({orderId: "o1"}),
    )
  )

  test("input that does not decode is refused before translate", () =>
    whenReceived(json([("status", "paid")]))->thenRefusedInput("orderId")
  )

  test("input translate declines is not understood", () =>
    whenInput({orderId: "o1", status: "lost"})->thenNotUnderstood("Unknown status: lost")
  )

  test("thenTranslateError is the older name", () =>
    whenInput({orderId: "o1", status: "lost"})->thenTranslateError("Unknown status: lost")
  )

  test("no commands is an answer", () =>
    whenInput({orderId: "o1", status: "pending"})->thenNoCommand
  )
})
