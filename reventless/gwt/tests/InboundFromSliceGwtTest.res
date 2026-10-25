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
// the buyer — which is what makes the fakes worth asserting on. A payment marked
// paid by hand is confirmed only for a caller in Finance, which is what makes the
// caller worth handing in.
module PaymentHook_Translation = {
  let moduleUrl = ""
  let translate = async (
    input: PaymentHook.externalInput,
    ~capabilities: Reventless.Capabilities.t,
    ~caller: option<Reventless.Identity.t>,
  ) =>
    switch input.status {
    | "paidByHand" =>
      switch caller {
      | Some(identity) if identity->Reventless.Identity.hasGroup("Finance") =>
        Ok([(input.orderId, PaymentHook.ConfirmPayment({orderId: input.orderId}))])
      | _ => Error("only Finance marks a payment paid by hand")
      }
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

let financeClerk: Reventless.Identity.t = {
  ...Reventless.Identity.anonymous,
  userId: "u_clerk",
  groups: ["Finance"],
}
let visitor = Reventless.Identity.anonymous

describe("InboundTranslation_GWT.FromSlice", () => {
  test("a door that reads its caller translates for the caller it admits", () =>
    whenInput({orderId: "o1", status: "paidByHand"}, ~caller=financeClerk)->thenCommand(
      "o1",
      ConfirmPayment({orderId: "o1"}),
    )
  )

  test("…and declines a caller it does not", () =>
    whenInput({orderId: "o1", status: "paidByHand"}, ~caller=visitor)->thenNotUnderstood(
      "only Finance marks a payment paid by hand",
    )
  )

  // No caller is the platform acting for itself, which this door does not admit.
  test("…and an input with no caller at all", () =>
    whenInput({orderId: "o1", status: "paidByHand"})->thenNotUnderstood(
      "only Finance marks a payment paid by hand",
    )
  )

  test("received JSON carries its caller through the decode", () =>
    whenReceived(
      json([("orderId", "o1"), ("status", "paidByHand")]),
      ~caller=financeClerk,
    )->thenCommand("o1", ConfirmPayment({orderId: "o1"}))
  )

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
