@@reventless.translation

// `orderId` is in the payload, so the envelope id adds nothing here.
let collect = (event, ~sourceId as _) =>
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
