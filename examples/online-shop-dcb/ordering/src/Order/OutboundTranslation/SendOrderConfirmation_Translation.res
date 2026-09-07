@@reventless.translation

// `orderId` is in the payload, so the envelope id adds nothing here.
let collect = (event, ~sourceId as _) =>
  switch event {
  | OrderPlaced({orderId, customerId}) => [(orderId, {orderId, customerId})]
  }

// This slice calls a service the framework does not broker, so it reaches its
// mailer directly and ignores the injected capabilities.
let translate = async (_id, item, ~capabilities as _) => {
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

// Nothing to say: a confirmation email that could not be sent is not a fact the
// order aggregate models, and inventing one to record a mail failure would put
// the mail server inside the domain. The Abandoned row is the record.
let onExhausted = (_id, _item, ~lastError as _) => None
