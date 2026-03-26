// SendOrderConfirmation OutboundTranslationSlice.
// When OrderPlaced is emitted, sends a confirmation email via EmailService.
// Fire-and-forget pattern (no inbound command).

let name = "SendOrderConfirmation"
let moduleUrl: string = %raw(`import.meta.url`)

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, customerId: string})

@schema
type outboundItem = {orderId: string, customerId: string}

@schema
type inboundCommand = unit

let collect = event =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId, {orderId, customerId})]
  }

let translate = async (_id, item) => {
  try {
    await EmailService.sendOrderConfirmation(
      ~email=item.customerId,
      ~orderId=item.orderId,
    )
    Ok(None)
  } catch {
  | exn =>
    let msg =
      exn
      ->JsExn.fromException
      ->Option.flatMap(JsExn.message)
      ->Option.getOr("email send failed")
    Error(msg)
  }
}

let maxRetries = 3
let heartbeatInterval = 60
