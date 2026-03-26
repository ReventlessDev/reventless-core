// Test fixtures for OutboundTranslationSlice callback tests.

// ─────────────────────────────────────────────────────────────
// Minimal DcbEventLog spec
// ─────────────────────────────────────────────────────────────

module OrderEventLog = {
  let moduleUrl: string = %raw(`import.meta.url`)
  @schema
  type event =
    | OrderShipped({orderId: @s.matches(Reventless.DcbTag.string) string, email: string})
    | PaymentReceived({orderId: @s.matches(Reventless.DcbTag.string) string, amount: float})
}

// ─────────────────────────────────────────────────────────────
// Fire-and-forget spec — translate returns Ok(None)
// ─────────────────────────────────────────────────────────────

module SendTrackingEmailSpec = {
  let name = "SendTrackingEmail"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent =
    | OrderShipped({orderId: string, email: string})

  @schema
  type outboundItem = {orderId: string, email: string}

  @schema
  type inboundCommand = unit

  let collect = event =>
    switch event {
    | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
    }

  let translate = async (_id, _item) => Ok(None)

  let maxRetries = 3
  let heartbeatInterval = 60
}

// ─────────────────────────────────────────────────────────────
// Command-back spec — translate returns Ok(Some(...))
// ─────────────────────────────────────────────────────────────

module ProcessPaymentSpec = {
  let name = "ProcessPayment"
  let moduleUrl: string = %raw(`import.meta.url`)

  @schema
  type consumedEvent =
    | PaymentReceived({orderId: string, amount: float})

  @schema
  type outboundItem = {orderId: string, amount: float}

  @schema
  type inboundCommand = ConfirmPayment({orderId: @s.matches(Reventless.DcbTag.string) string})

  let collect = event =>
    switch event {
    | PaymentReceived({orderId, amount}) => [(orderId, {orderId, amount})]
    }

  // Simulate calling external payment gateway, then return a command
  let translateFn: ref<(string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>> = ref(
    async (id, _item) => Ok(Some((id, ConfirmPayment({orderId: id}))))
  )

  let translate = (id, item) => translateFn.contents(id, item)

  let maxRetries = 2
  let heartbeatInterval = 30
}
