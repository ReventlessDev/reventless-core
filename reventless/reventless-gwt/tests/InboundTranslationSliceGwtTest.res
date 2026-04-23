// Worked example for InboundTranslationSlice_GWT — a payment webhook that
// translates `status` into either a `ConfirmPayment` command or a
// translation error for unknown statuses.

module PaymentWebhookSlice = {
  let name = "PaymentWebhook"

  @schema
  type externalInput = {paymentId: string, orderId: string, status: string}

  @schema
  type command = ConfirmPayment({orderId: string, paymentId: string})

  let translate = input =>
    switch input.status {
    | "completed" =>
      Ok([(input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId}))])
    | _ => Error("Unknown payment status: " ++ input.status)
    }
}

include InboundTranslationSlice_GWT.Make(PaymentWebhookSlice)

describe("PaymentWebhook InboundTranslationSlice", () => {
  test("completed status emits ConfirmPayment", () =>
    whenInput({paymentId: "p1", orderId: "o1", status: "completed"})
    ->thenCommand("o1", ConfirmPayment({orderId: "o1", paymentId: "p1"}))
  )

  test("unknown status surfaces translate error", () =>
    whenInput({paymentId: "p1", orderId: "o1", status: "garbage"})
    ->thenTranslateError("Unknown payment status: garbage")
  )
})
