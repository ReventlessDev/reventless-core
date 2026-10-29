@@reventless.translation

// Keyed by address, arm and time, so a registration made again after one lapsed,
// or a code reissued, is new work rather than work already done.
let collect = (event, ~sourceId as _) =>
  switch event {
  | RegistrationRequested({email, address, requestedAt}) => [
      (
        `${email}:${requestedAt->Reventless.DateTime.toString}`,
        {email, address, alreadyRegistered: false},
      ),
    ]
  | RegistrationInvited({email, address, roles, invitedAt}) => [
      (
        `${email}:invited:${invitedAt->Reventless.DateTime.toString}`,
        {email, address, alreadyRegistered: false, invited: true, roles},
      ),
    ]
  | RegistrationChallengeReissued({email, address, reissuedAt, ?invitedBy}) => [
      (
        `${email}:reissued:${reissuedAt->Reventless.DateTime.toString}`,
        {email, address, alreadyRegistered: false, invited: invitedBy->Option.isSome},
      ),
    ]
  | RegistrationAttemptedOnTakenAddress({email, address, attemptedAt}) => [
      (
        `${email}:taken:${attemptedAt->Reventless.DateTime.toString}`,
        {email, address, alreadyRegistered: true},
      ),
    ]
  }

let expiresIn = (~invited) =>
  RegistrationChallenge.policyFor(
    RegistrationChallenge.purposeFor(~invited),
  ).tokenTtl->Reventless.Duration.format

let challengeBody = (~token) =>
  `Your registration code is ${token}. Enter it with a password of your choice to finish. It expires in ${expiresIn(
      ~invited=false,
    )}.`

/** What the invitation grants, as the mail says it: "as Merchandiser", or
    nothing where the event did not say. */
let asRoles = (roles: option<array<string>>) =>
  switch roles {
  | Some([]) | None => ""
  | Some(roles) => ` as ${roles->Array.join(" and ")}`
  }

let invitationBody = (~token, ~roles=?) =>
  `You have been invited to create an account${asRoles(
      roles,
    )}. Your code is ${token}. Enter it with this address and a password of your choice to accept. It expires in ${expiresIn(
      ~invited=true,
    )}.`

let noticeBody = "Someone asked to register an account with this address, which already has one. If it was you, sign in instead. If it was not, there is nothing to do: no account was changed."

let send = (capabilities: Reventless.Capabilities.t, ~address, ~subject, ~body) =>
  capabilities.messaging.send(
    ~recipient=ToEmail(address),
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
      ~address=item.address,
      ~subject="Someone tried to register with your address",
      ~body=noticeBody,
    ) {
    | Ok(_) => Ok(None)
    | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
    }
  } else {
    let invited = item.invited->Option.getOr(false)
    let policy = RegistrationChallenge.policyFor(RegistrationChallenge.purposeFor(~invited))
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
          ~address=item.address,
          ~subject=invited ? "You are invited to create an account" : "Finish your registration",
          ~body=invited ? invitationBody(~token, ~roles=?item.roles) : challengeBody(~token),
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
