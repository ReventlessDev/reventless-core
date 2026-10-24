@@reventless.translation

module V = ContactVerification

let policy = V.emailPolicy

// Keyed by address and time, so a registration made again after one lapsed is
// new work rather than work already done.
let collect = (event, ~sourceId as _) =>
  switch event {
  | RegistrationRequested({email, requestedAt}) => [
      (`${email}:${requestedAt->Reventless.DateTime.toString}`, {email, alreadyRegistered: false}),
    ]
  | RegistrationAttemptedOnTakenAddress({email, attemptedAt}) => [
      (
        `${email}:taken:${attemptedAt->Reventless.DateTime.toString}`,
        {email, alreadyRegistered: true},
      ),
    ]
  }

let challengeBody = (~token) =>
  `Your registration code is ${token}. Enter it with a password of your choice to finish. It expires in ${policy.tokenTtl->Reventless.Duration.format}.`

let noticeBody = "Someone asked to register an account with this address, which already has one. If it was you, sign in instead. If it was not, there is nothing to do: no account was changed."

let send = (capabilities: Reventless.Capabilities.t, ~email, ~subject, ~body) =>
  capabilities.messaging.send(
    ~recipient=ToEmail(Reventless.Email.unsafe(email)),
    ~message={subject, body},
  )

/**
Draw a secret, send it, and open a challenge against its hash — sending first,
so the hash that is recorded is always the one that was delivered.
*/
let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>
  if item.alreadyRegistered {
    switch await send(
      capabilities,
      ~email=item.email,
      ~subject="Someone tried to register with your address",
      ~body=noticeBody,
    ) {
    | Ok(_) => Ok(None)
    | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
    }
  } else {
    switch capabilities.secrets.randomToken(
      ~length=policy.proofLength,
      ~alphabet=policy.proofAlphabet,
    ) {
    | Error(Unavailable(why)) => Error(`no secret source: ${why}`)
    | Ok(token) =>
      switch capabilities.secrets.hash(token) {
      | Error(Unavailable(why)) => Error(`cannot hash a secret: ${why}`)
      | Ok(proofHash) =>
        switch await send(
          capabilities,
          ~email=item.email,
          ~subject="Finish your registration",
          ~body=challengeBody(~token),
        ) {
        | Ok(_) =>
          Ok(
            Some((
              item.email,
              IssueRegistrationChallenge({
                email: ContactAddressId.makeFromString(item.email),
                proofHash,
                issuedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
              }),
            )),
          )
        | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
        }
      }
    }
  }

let onExhausted = (_id, _item: outboundItem, ~lastError as _) => None
