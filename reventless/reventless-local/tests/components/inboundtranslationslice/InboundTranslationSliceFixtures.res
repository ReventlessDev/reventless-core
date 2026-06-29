// Test fixtures for InboundTranslationSlice callback tests.

// ─────────────────────────────────────────────────────────────
// Minimal DcbEventLog spec
// ─────────────────────────────────────────────────────────────

module OrderEventLog = {
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type event =
    | PaymentConfirmed({orderId: @s.matches(Reventless.DcbTag.string) string, paymentId: string})
}

// ─────────────────────────────────────────────────────────────
// InboundTranslationSlice spec — payment webhook
// ─────────────────────────────────────────────────────────────

module PaymentWebhookSpec = {
  let name = "PaymentWebhook"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type externalInput = {paymentId: string, orderId: string, status: string}

  @schema
  type command = ConfirmPayment({orderId: @s.matches(Reventless.DcbTag.string) string, paymentId: string})

  let targetName = "ConfirmPayment"
  let externalSystem = None

  let translate = (input: externalInput) =>
    switch input.status {
    | "completed" =>
      Ok([(input.orderId, ConfirmPayment({orderId: input.orderId, paymentId: input.paymentId}))])
    | status => Error("Unknown payment status: " ++ status)
    }
}
