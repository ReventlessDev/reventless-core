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

  let collect = (event, ~sourceId as _) =>
    switch event {
    | OrderShipped({orderId, email}) => [(orderId, {orderId, email})]
    }

  let translate = async (_id, _item, ~capabilities as _) => Ok(None)
  let onExhausted = (_id, _item, ~lastError as _) => None

  let maxRetries = 3
  let heartbeatInterval = 60
  let targetName = None
  let sourceNames: array<string> = []
  let externalSystem = None
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let traits: array<Reventless.Trait.t> = []
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

  let collect = (event, ~sourceId as _) =>
    switch event {
    | PaymentReceived({orderId, amount}) => [(orderId, {orderId, amount})]
    }

  // Simulate calling external payment gateway, then return a command
  let translateFn: ref<(string, outboundItem) => promise<result<option<(string, inboundCommand)>, string>>> = ref(
    async (id, _item) => Ok(Some((id, ConfirmPayment({orderId: id}))))
  )

  // The mock stays two-arg: a test that wants to vary behaviour varies it on
  // the item, and threading capabilities into every fixture would make each
  // one restate a type it does not use.
  let translate = (id, item, ~capabilities as _) => translateFn.contents(id, item)

  // Overridable like `translateFn`, so a test can assert both answers a slice may
  // give when its budget runs out: say nothing, or tell the domain.
  let onExhaustedFn: ref<(string, outboundItem, option<string>) => option<(string, inboundCommand)>> = ref(
    (_id, _item, _lastError) => None
  )
  let onExhausted = (id, item, ~lastError) => onExhaustedFn.contents(id, item, lastError)

  let maxRetries = 2
  let heartbeatInterval = 30
  let targetName = Some("ConfirmPayment")
  let sourceNames: array<string> = []
  let externalSystem = None
  let capabilityNeeds: array<Reventless.CapabilityNeed.t> = []
  let traits: array<Reventless.Trait.t> = []
}
