@@reventless.translation

// Keyed by address, arm and time, so a registration made again after one lapsed,
// or a code reissued, is new work rather than work already done.
let collect = (event, ~sourceId as _) =>
  switch event {
  | RegistrationRequested({emailId, email: Value(email), requestedAt}) => [
      (
        `${emailId}:${requestedAt->Reventless.DateTime.toString}`,
        {emailId, email, alreadyRegistered: false},
      ),
    ]
  | RegistrationInvited({emailId, email: Value(email), roles, invitedAt}) => [
      (
        `${emailId}:invited:${invitedAt->Reventless.DateTime.toString}`,
        {emailId, email, alreadyRegistered: false, invited: true, roles},
      ),
    ]
  | RegistrationChallengeReissued({emailId, email: Value(email), reissuedAt, ?invitedBy}) => [
      (
        `${emailId}:reissued:${reissuedAt->Reventless.DateTime.toString}`,
        {emailId, email, alreadyRegistered: false, invited: invitedBy->Option.isSome},
      ),
    ]
  | RegistrationAttemptedOnTakenAddress({emailId, email: Value(email), attemptedAt}) => [
      (
        `${emailId}:taken:${attemptedAt->Reventless.DateTime.toString}`,
        {emailId, email, alreadyRegistered: true},
      ),
    ]
  // An address that was erased or forgotten has nobody left to write to.
  | _ => []
  }

// The mails' words, by key, in the English a deployment with no catalogue sends. A translation
// is a catalogue's `registration.*` keys; `pnpm run check:server-catalogues` keeps
// `i18n/en.json` the same as these.
module Messages = {
  let challengeSubject: Reventless.Text.message = {
    key: "registration.challenge.subject",
    source: "Finish your registration",
  }
  let challengeBody: Reventless.Text.message = {
    key: "registration.challenge.body",
    source: "Your registration code is {token}. Enter it with a password of your choice to finish. It expires in {expiresIn}.",
  }
  let invitedSubject: Reventless.Text.message = {
    key: "registration.invited.subject",
    source: "You are invited to create an account",
  }
  let invitedBody: Reventless.Text.message = {
    key: "registration.invited.body",
    source: "You have been invited to create an account{hasRoles, select, yes { as {roles}} other {}}. Your code is {token}. Enter it with this address and a password of your choice to accept. It expires in {expiresIn}.",
  }
  let takenSubject: Reventless.Text.message = {
    key: "registration.taken.subject",
    source: "Someone tried to register with your address",
  }
  let takenBody: Reventless.Text.message = {
    key: "registration.taken.body",
    source: "Someone asked to register an account with this address, which already has one. If it was you, sign in instead. If it was not, there is nothing to do: no account was changed.",
  }
  let all = [challengeSubject, challengeBody, invitedSubject, invitedBody, takenSubject, takenBody]
}

let expiresIn = (~invited) =>
  RegistrationChallenge.policyFor(RegistrationChallenge.purposeFor(~invited)).tokenTtl

let challengeValues = (~token) =>
  dict{
    "token": Reventless.MessageFormat.Text(token),
    "expiresIn": Duration(expiresIn(~invited=false)),
  }

/** What the invitation grants, as the mail says it: "as Merchandiser", or nothing where the
    event did not say. */
let invitationValues = (~token, ~roles: option<array<string>>=?) => {
  let roles = roles->Option.getOr([])
  dict{
    "token": Reventless.MessageFormat.Text(token),
    "expiresIn": Duration(expiresIn(~invited=true)),
    "hasRoles": Text(roles == [] ? "no" : "yes"),
    "roles": List(roles),
  }
}

/** The mails in English, as a deployment with no catalogue sends them. */
let challengeBody = (~token) =>
  Messages.challengeBody->Reventless.Text.inSource(~values=challengeValues(~token))

let invitationBody = (~token, ~roles=?) =>
  Messages.invitedBody->Reventless.Text.inSource(~values=invitationValues(~token, ~roles?))

let noticeBody = Messages.takenBody->Reventless.Text.inSource

let send = async (capabilities: Reventless.Capabilities.t, ~email, ~subject, ~body, ~values) => {
  let recipient: Reventless.Messaging.recipient = ToEmail(email)
  switch await capabilities.text->Reventless.Text.compose(~recipient, ~subject, ~body, ~values) {
  | Error(reason) => Error(reason)
  | Ok(message) =>
    switch await capabilities.messaging.send(~recipient, ~message) {
    | Ok(receipt) => Ok(receipt)
    | Error(failure) => Error(Reventless.Messaging.failureReason(failure))
    }
  }
}

/**
Draw a secret, send it, and open a challenge against its hash — sending first,
so the hash that is recorded is always the one that was delivered.
*/
let translate = async (_id, item: outboundItem, ~capabilities: Reventless.Capabilities.t) =>
  if item.alreadyRegistered {
    switch await send(
      capabilities,
      ~email=item.email,
      ~subject=Messages.takenSubject,
      ~body=Messages.takenBody,
      ~values=Dict.make(),
    ) {
    | Ok(_) => Ok(None)
    | Error(reason) => Error(reason)
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
          ~email=item.email,
          ~subject=invited ? Messages.invitedSubject : Messages.challengeSubject,
          ~body=invited ? Messages.invitedBody : Messages.challengeBody,
          ~values=invited ? invitationValues(~token, ~roles=?item.roles) : challengeValues(~token),
        ) {
        | Ok(_) =>
          Ok(
            Some((
              item.emailId,
              IssueRegistrationChallenge({
                emailId: ContactAddressId.makeFromString(item.emailId),
                proofHash,
                issuedAt: Date.make()->Date.toISOString->Reventless.DateTime.unsafe,
              }),
            )),
          )
        | Error(reason) => Error(reason)
        }
      }
    }
  }

let onExhausted = (_id, _item: outboundItem, ~lastError as _) => None
