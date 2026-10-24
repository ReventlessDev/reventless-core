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
  let endpoint = None
  type role = Reventless.Role.name
  let authorizationOf = _ => Reventless.Authorization.AllowAuthenticated
  let capabilityNeeds = [Reventless.CapabilityNeed.Messaging]
}

// Confirms a paid order and, through the capability `translate` is handed, tells
// the buyer — which is what makes the fakes worth asserting on.
module PaymentHook_Translation = {
  let moduleUrl = ""
  let translate = async (
    input: PaymentHook.externalInput,
    ~capabilities: Reventless.Capabilities.t,
  ) =>
    switch input.status {
    | "paid" =>
      switch await capabilities.messaging.send(
        ~recipient=ToEmail(Reventless.Email.unsafe("buyer@example.com")),
        ~message={subject: "Paid", body: input.orderId},
      ) {
      | Ok(_) => Ok([(input.orderId, PaymentHook.ConfirmPayment({orderId: input.orderId}))])
      | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
      }
    | "pending" => Ok([])
    | "broken" => JsError.throwWithMessage("the translation threw")
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

  test("translate reaches the capabilities it is handed", () =>
    whenInput({orderId: "o1", status: "paid"})->thenSent([
      Sent({
        recipient: ToEmail(Reventless.Email.unsafe("buyer@example.com")),
        message: {subject: "Paid", body: "o1"},
      }),
    ])
  )

  test("a capability failure is the translation declining the input", () =>
    whenInput(
      {orderId: "o1", status: "paid"},
      ~fakes=fakes(~send=async (~recipient as _, ~message as _) => Error(Unavailable("down")), ()),
    )->thenNotUnderstood("down")
  )

  test("a translation that throws declined the input", () =>
    whenInput({orderId: "o1", status: "broken"})->thenNotUnderstood("the translation threw")
  )

  test("input that never translated sent nothing", () =>
    whenReceived(json([("status", "paid")]))->thenNothingSent
  )
})
