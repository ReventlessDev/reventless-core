@@reventless.translation

// Keyed by the request's own reference: one message per decision, and a redelivery
// of the same event lands on the row that is already there.
let collect = (event, ~sourceId as _) =>
  switch event {
  | NotificationRequested({recipientId, reference, channel, address, subject, body}) => [
      (reference, {recipientId, reference, channel, address, subject, body}),
    ]
  }

// The one place the domain's channel vocabulary meets the platform's. Two
// declarations rather than one shared type because a schema type has to travel
// on the wire and the capability's does not — and this switch is where a channel
// the platform grows would show up as a compile error rather than as a silence.
let recipientFor = (item: outboundItem) =>
  switch item.channel {
  | Email =>
    item.address
    ->Reventless.Email.fromString
    ->Result.map(email => Reventless.Messaging.ToEmail(email))
  | Sms =>
    item.address->Reventless.Phone.fromString->Result.map(phone => Reventless.Messaging.ToSms(phone))
  | Push => Ok(Reventless.Messaging.ToPush({deviceToken: item.address}))
  }

let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>
  switch recipientFor(item) {
  // An address the directory holds that its own channel's grammar refuses. Not
  // retryable and not the provider's fault, so it is recorded as a failure
  // rather than raised: the recipient's row is what needs fixing.
  | Error(why) =>
    Ok(
      Some((
        item.recipientId,
        RecordDeliveryFailure({
          recipientId: item.recipientId,
          reference: item.reference,
          reason: why,
        }),
      )),
    )
  | Ok(recipient) =>
    switch await capabilities.messaging.send(
      ~recipient,
      ~message={subject: item.subject, body: item.body},
    ) {
    | Ok({ref}) =>
      Ok(
        Some((
          item.recipientId,
          RecordDelivery({
            recipientId: item.recipientId,
            reference: item.reference,
            providerRef: ref,
          }),
        )),
      )
    // The retry split, taken from the port rather than re-decided here. An outage
    // goes back as `Error` and is swept; a refusal is settled, so reporting it as
    // a failure now beats spending two more attempts to learn the same thing.
    | Error(failure) =>
      Reventless.Messaging.retriable(failure)
        ? Error(Reventless.Messaging.failureReason(failure))
        : Ok(
            Some((
              item.recipientId,
              RecordDeliveryFailure({
                recipientId: item.recipientId,
                reference: item.reference,
                reason: Reventless.Messaging.failureReason(failure),
              }),
            )),
          )
    }
  }

// The budget is spent and the provider never answered. Recording it beats leaving
// the row pending forever — and it is the second reason the capability must be
// declared, since an unprovisioned sender reaches here every single time.
let onExhausted = (_id, item: outboundItem, ~lastError) =>
  Some((
    item.recipientId,
    RecordDeliveryFailure({
      recipientId: item.recipientId,
      reference: item.reference,
      reason: lastError->Option.getOr("the messaging provider never answered"),
    }),
  ))
