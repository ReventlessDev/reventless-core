// Amazon SES as a messaging transport for unattended callers.
//
// Policy — who a message can be addressed to, what a send can answer, and which
// failures are worth retrying — lives in `Reventless.Messaging`, shared with
// every other transport. This module only knows how to ask SES and how to turn
// its answer into that vocabulary.
//
// Runtime-pure: no Pulumi import, so it can be bundled into a Lambda entry point
// without dragging deploy-time modules into the cold-start graph.

module Send = AwsSdk.SES.SendEmailCommand

/**
The channels this transport can attempt, given what the deployment provisioned.

Derived from the sender address rather than declared beside it: SES sends from a
verified identity, so no address means no email channel, and a list that claimed
one anyway would be a promise the first send breaks. SMS and push are not wired
here — `Messaging.UnsupportedChannel` is what a caller gets, which is settled
rather than retried, so a preference for a channel this deployment does not run
costs one refusal and not a retry budget.
*/
let channels = (~sender: string): array<Reventless.Messaging.channel> =>
  sender == "" ? [] : [Email]

/**
Send one message.

`Refused` rather than a blank subject line for a message that carries none: SES
requires one, retrying will not produce one, and a delivered email with an empty
header is the outcome nobody wanted. The other two arms follow the port's retry
rule — an unset sender is the deployment's gap (`Unavailable`, retried and swept)
and anything SES itself refuses is settled.
*/
let send = async (
  ~sender: string,
  ~recipient: Reventless.Messaging.recipient,
  ~message: Reventless.Messaging.message,
): result<Reventless.Messaging.receipt, Reventless.Messaging.failure> =>
  switch recipient {
  | ToSms(_) => Error(UnsupportedChannel(Sms))
  | ToPush(_) => Error(UnsupportedChannel(Push))
  | ToEmail(address) =>
    if sender == "" {
      Error(Unavailable("no messaging sender configured (MESSAGING_EMAIL_SENDER unset)"))
    } else {
      switch message.subject {
      | None | Some("") => Error(Refused("an email needs a subject, and this message carries none"))
      | Some(subject) =>
        switch await Send.send(
          Send.make({
            fromEmailAddress: sender,
            destination: {toAddresses: [address->Reventless.Email.toString]},
            content: {
              simple: {
                subject: {data: subject},
                body: {text: {data: message.body}},
              },
            },
          }),
        ) {
        // SES answers 200 with no MessageId only if the shape changed under us;
        // an accepted message without an id is still accepted, and inventing one
        // would put a value in a receipt that no support conversation resolves.
        | resp => Ok({ref: resp.messageId->Option.getOr("")})
        | exception exn =>
          let msg = exn->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr("unknown")
          // Every SES error is treated as transient. The permanent ones it does
          // raise — an unverified identity, an address on the suppression list —
          // are deployment or recipient state that a sweep should keep surfacing,
          // and reading them apart means matching on message text, which is a
          // provider's prose and not a contract.
          Error(Unavailable(msg))
        }
      }
    }
  }

/** The port, closed over the deployment's sender. What a Lambda entry point puts
    on `Capabilities.messaging`. */
let provider = (~sender: string): Reventless.Messaging.provider => {
  channels: channels(~sender),
  send: (~recipient, ~message) => send(~sender, ~recipient, ~message),
}
